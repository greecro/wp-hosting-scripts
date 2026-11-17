<?php
/**
 * Bestellungen nach Ablauf der Aufbewahrungsfrist anonymisieren (Jahreslauf).
 *
 * Aufruf (durch order-anonymize.sh, als Site-User):
 *   wp eval-file order-anonymize.php <apply|dry> <max-jahr|auto|-> <batch> <nur-ids|-> <halte-ids|-> <basend|->
 *
 * Bezugsjahr einer Bestellung = Jahr (Zeitzone der Site) des jüngsten Datums aus Bestellung, Zahlung,
 * Abschluss, Erstattung und Rechnung (_wcpdf_invoice_date). Fällig, wenn Bezugsjahr <= laufendes Jahr - 9
 * (Buchungsbelege: 8 Jahre ab Ende des Kalenderjahres). --max-year kann diese Grenze nur senken.
 *
 * Nicht angefasst werden: bereits anonymisierte Bestellungen (_anonymized = yes), Bestellungen mit der
 * Meta wph_retention_hold (beliebiger Wert), mit einer Rechnungsnummer (_wcpdf_invoice_number) und die
 * IDs aus der Haltedatei des Servers (/etc/wp-hosting/retention-hold-<domain>.txt, übergeben als <halte-ids>).
 *
 * Anonymisiert wird über WC_Privacy_Erasers::remove_order_personal_data() (Adressen, E-Mail, Telefon, IP,
 * Browserkennung, Bestellnotizen, Zahler-Meta). Dazu kommt, was WooCommerce stehen lässt:
 *   - Kundennotiz, PayPal-Zahler-E-Mail, Matomo-IP und -Browserkennung, Attribution-Browserkennung
 *     (Liste per Filter wph_order_anonymize_extra_meta_keys erweiterbar),
 *   - Inhaberfelder der FS-License-Manager-Schlüssel dieser Bestellung (Schlüssel und Bestellbezug bleiben).
 *   - Die Analytics-Kundenzeile wird nur anonymisiert, wenn die Person keine weitere, nicht anonymisierte
 *     Bestellung hat. WooCommerce würde sie sonst auch bei aktiven Kunden überschreiben.
 *
 * Mit dem Schalter --basend feuert vor jeder Anonymisierung die Action wph_order_retention_anonymize( $order_id )
 * (nur die Bestell-ID, keine Personendaten), damit ein Plugin die IDs sammeln und z. B. an BaseSend melden kann.
 * Standard aus. Das Skript selbst ruft keinen Dienst auf. Anonymisierte Bestellungen tragen die Meta
 * wph_retention_anonymized; das mu-plugin privacy-erasure nimmt sie über basend_skip_order vom Abgleich aus.
 *
 * Ohne "apply" wird nichts geschrieben. Ausgabe und Protokoll enthalten nur Zahlen, nie Personendaten.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

global $wpdb;

$mode     = ( ( $args[0] ?? 'dry' ) === 'apply' ) ? 'apply' : 'dry';
$year_arg = (string) ( $args[1] ?? '-' );
$batch    = (int) ( $args[2] ?? 200 );
$parse_ids = static function ( $raw ) {
	if ( '-' === $raw || '' === $raw ) {
		return null;
	}
	$ids = array_values( array_unique( array_filter( array_map( 'intval', explode( ',', (string) $raw ) ) ) ) );
	if ( ! $ids ) {
		WP_CLI::error( 'Ungültige ID-Liste.' );
	}
	return $ids;
};
$only      = $parse_ids( (string) ( $args[3] ?? '-' ) );
$hold_file = array_flip( (array) $parse_ids( (string) ( $args[4] ?? '-' ) ) );
$basend    = ( ( $args[5] ?? '-' ) === 'basend' );

if ( $batch < 10 || $batch > 1000 ) {
	WP_CLI::error( 'Batch-Größe muss zwischen 10 und 1000 liegen.' );
}
if ( ! class_exists( 'WooCommerce' ) ) {
	echo "Übersprungen: WooCommerce nicht aktiv.\n";
	return;
}
if ( ! \Automattic\WooCommerce\Utilities\OrderUtil::custom_orders_table_usage_is_enabled() ) {
	// Alte Speicherung (Bestellungen als Beiträge): ohne Bestellungen gibt es nichts zu tun, mit Bestellungen
	// darf das nicht still durchlaufen, denn dann bliebe die Frist unerfüllt.
	$legacy = (int) $wpdb->get_var( "SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type IN ('shop_order', 'shop_order_refund')" );
	if ( 0 === $legacy ) {
		echo "Übersprungen: HPOS ist aus und es gibt keine Bestellungen.\n";
		return;
	}
	WP_CLI::error( "HPOS ist nicht aktiv, aber {$legacy} Bestellungen liegen als Beiträge. Dieses Skript arbeitet nur mit der Bestelltabelle (wc_orders): HPOS aktivieren und migrieren." );
}

// --- Grenze --------------------------------------------------------------------------------------------------

$this_year = (int) wp_date( 'Y' );
$allowed   = $this_year - 9;
if ( 'auto' === $year_arg ) {
	$max_year = $allowed;
} elseif ( ctype_digit( $year_arg ) ) {
	$max_year = (int) $year_arg;
} elseif ( 'dry' === $mode && '-' === $year_arg ) {
	$max_year = $allowed;
} else {
	WP_CLI::error( 'Für den Echtlauf ist --max-year <JJJJ|auto> Pflicht.' );
}
if ( $max_year > $allowed ) {
	WP_CLI::error( "max-year {$max_year} liegt über der Grenze {$allowed} (laufendes Jahr {$this_year} minus 9)." );
}

// --- Daten laden ---------------------------------------------------------------------------------------------

$o  = $wpdb->prefix . 'wc_orders';
$op = $wpdb->prefix . 'wc_order_operational_data';
$m  = $wpdb->prefix . 'wc_orders_meta';

$ts = static function ( $value ) {
	if ( null === $value || '' === $value || 0 === strpos( (string) $value, '0000-00-00' ) ) {
		return 0;
	}
	if ( ctype_digit( (string) $value ) ) {
		return (int) $value;
	}
	$t = strtotime( $value . ' UTC' );
	return $t ? (int) $t : 0;
};

$orders  = $wpdb->get_results( "SELECT o.id, o.date_created_gmt AS c, op.date_paid_gmt AS p, op.date_completed_gmt AS d FROM {$o} o LEFT JOIN {$op} op ON op.order_id = o.id WHERE o.type = 'shop_order'", ARRAY_A );
$refunds = array();
foreach ( (array) $wpdb->get_results( "SELECT parent_order_id AS pid, MAX(date_created_gmt) AS r FROM {$o} WHERE type = 'shop_order_refund' GROUP BY parent_order_id", ARRAY_A ) as $row ) {
	$refunds[ (int) $row['pid'] ] = $ts( $row['r'] );
}
$invoice_date = array();
$has_invoice  = array();
$anonymized   = array();
$hold_meta    = array();
foreach ( (array) $wpdb->get_results( "SELECT order_id, meta_key, meta_value FROM {$m} WHERE meta_key IN ('_wcpdf_invoice_date','_wcpdf_invoice_number','_anonymized','wph_retention_hold')", ARRAY_A ) as $row ) {
	$id = (int) $row['order_id'];
	switch ( $row['meta_key'] ) {
		case '_wcpdf_invoice_date':
			$invoice_date[ $id ] = max( $invoice_date[ $id ] ?? 0, $ts( $row['meta_value'] ) );
			break;
		case '_wcpdf_invoice_number':
			if ( '' !== (string) $row['meta_value'] ) {
				$has_invoice[ $id ] = true;
			}
			break;
		case '_anonymized':
			if ( 'yes' === $row['meta_value'] ) {
				$anonymized[ $id ] = true;
			}
			break;
		case 'wph_retention_hold':
			if ( '' !== (string) $row['meta_value'] ) {
				$hold_meta[ $id ] = true;
			}
			break;
	}
}

// --- Einordnung ------------------------------------------------------------------------------------------------

$years   = array();
$due_ids = array();
$holds   = array( 'Meta' => array( 0, 0 ), 'Datei' => array( 0, 0 ), 'Rechnung' => array( 0, 0 ) ); // gesamt, davon fällig
$no_date = 0;
foreach ( $orders as $row ) {
	$id   = (int) $row['id'];
	$best = max( $ts( $row['c'] ), $ts( $row['p'] ), $ts( $row['d'] ), $refunds[ $id ] ?? 0, $invoice_date[ $id ] ?? 0 );
	if ( $best <= 0 ) {
		$no_date++;
		continue;
	}
	$y = (int) wp_date( 'Y', $best );
	if ( ! isset( $years[ $y ] ) ) {
		$years[ $y ] = array( 'gesamt' => 0, 'anon' => 0, 'hold' => 0, 'frei' => 0, 'lauf' => 0 );
	}
	$years[ $y ]['gesamt']++;

	if ( isset( $anonymized[ $id ] ) ) {
		$years[ $y ]['anon']++;
		continue;
	}
	$hold = isset( $hold_file[ $id ] ) ? 'Datei' : ( isset( $hold_meta[ $id ] ) ? 'Meta' : ( isset( $has_invoice[ $id ] ) ? 'Rechnung' : '' ) );
	if ( '' !== $hold ) {
		$years[ $y ]['hold']++;
		$holds[ $hold ][0]++;
		if ( $y <= $allowed ) {
			$holds[ $hold ][1]++;
		}
		continue;
	}
	if ( $y <= $allowed ) {
		$years[ $y ]['frei']++;
		if ( $y <= $max_year && ( null === $only || in_array( $id, $only, true ) ) ) {
			$years[ $y ]['lauf']++;
			$due_ids[] = $id;
		}
	}
}
ksort( $years );
sort( $due_ids );

echo "Grenze: Bezugsjahr <= {$allowed} (laufendes Jahr {$this_year} minus 9); dieser Lauf: <= {$max_year}" . ( null !== $only ? ' (nur ausgewählte IDs)' : '' ) . "\n";
echo 'Bestellungen gesamt: ' . count( $orders ) . ( $no_date ? " (ohne Datum, übersprungen: {$no_date})" : '' ) . "\n";
printf( "%-11s %8s %13s %9s %14s %12s\n", 'Bezugsjahr', 'gesamt', 'anonymisiert', 'gehalten', "fällig(<={$allowed})", "Lauf(<={$max_year})" );
$sum = array( 'gesamt' => 0, 'anon' => 0, 'hold' => 0, 'frei' => 0, 'lauf' => 0 );
foreach ( $years as $y => $c ) {
	printf( "%-11d %8d %13d %9d %14d %12d\n", $y, $c['gesamt'], $c['anon'], $c['hold'], $c['frei'], $c['lauf'] );
	foreach ( $sum as $k => $_ ) {
		$sum[ $k ] += $c[ $k ];
	}
}
printf( "%-11s %8d %13d %9d %14d %12d\n", 'Summe', $sum['gesamt'], $sum['anon'], $sum['hold'], $sum['frei'], $sum['lauf'] );
foreach ( $holds as $name => $c ) {
	echo "Gehalten ({$name}): {$c[0]}, davon im fälligen Bereich: {$c[1]}\n";
}

if ( 'apply' !== $mode ) {
	echo "Trockenlauf: nichts geschrieben.\n";
	return;
}

// --- Echtlauf ----------------------------------------------------------------------------------------------------

$addr_t  = $wpdb->prefix . 'wc_order_addresses';
$stats_t = $wpdb->prefix . 'wc_order_stats';
$fslm_t  = $wpdb->prefix . 'wc_fs_product_licenses_keys';
$has_fslm  = ( $fslm_t === $wpdb->get_var( $wpdb->prepare( 'SHOW TABLES LIKE %s', $fslm_t ) ) );
$has_stats = ( $stats_t === $wpdb->get_var( $wpdb->prepare( 'SHOW TABLES LIKE %s', $stats_t ) ) );

if ( ! class_exists( 'WC_Privacy_Erasers' ) ) {
	include_once WC_ABSPATH . 'includes/class-wc-privacy-erasers.php';
}
if ( ! class_exists( 'WC_Privacy_Erasers' ) ) {
	WP_CLI::error( 'WC_Privacy_Erasers nicht gefunden.' );
}

$extra_keys = apply_filters(
	'wph_order_anonymize_extra_meta_keys',
	array( '_ppcp_paypal_payer_email', '_piwik_ipaddress', '_piwik_useragent', '_wc_order_attribution_user_agent' )
);
$extra_keys = array_values( array_unique( array_filter( array_map( 'strval', (array) $extra_keys ) ) ) );
$kph        = implode( ',', array_fill( 0, count( $extra_keys ), '%s' ) );

// Analytics-Kundenzeile selbst steuern (siehe Kopfkommentar): Rückruf von WooCommerce aushängen.
$lookup_cb = null;
global $wp_filter;
if ( isset( $wp_filter['woocommerce_privacy_remove_order_personal_data'] ) ) {
	foreach ( $wp_filter['woocommerce_privacy_remove_order_personal_data']->callbacks as $prio => $cbs ) {
		foreach ( $cbs as $cb ) {
			$f = $cb['function'];
			if ( ( is_array( $f ) && isset( $f[1] ) && 'anonymize_customer' === $f[1] ) || ( is_string( $f ) && false !== strpos( $f, '::anonymize_customer' ) ) ) {
				$lookup_cb = array( $f, $prio );
			}
		}
	}
}
if ( $lookup_cb ) {
	remove_action( 'woocommerce_privacy_remove_order_personal_data', $lookup_cb[0], $lookup_cb[1] );
}

$done        = 0;
$keys_empty  = 0;
$lookups     = 0;
$errors      = 0;
$verify_fail = 0;

foreach ( array_chunk( $due_ids, $batch ) as $chunk ) {
	$done_ids = array();
	foreach ( $chunk as $id ) {
		try {
			$order = wc_get_order( $id );
			if ( ! $order instanceof WC_Order || 'yes' === (string) $order->get_meta( '_anonymized' ) ) {
				continue;
			}
			$email = (string) $order->get_billing_email();
			$ip0   = (string) $order->get_customer_ip_address( 'edit' );
			$ua0   = (string) $order->get_customer_user_agent( 'edit' );
			if ( $basend ) {
				do_action( 'wph_order_retention_anonymize', $id );
			}

			WC_Privacy_Erasers::remove_order_personal_data( $order );
			$order->set_customer_note( '' );
			foreach ( $extra_keys as $k ) {
				$order->delete_meta_data( $k );
			}
			$order->update_meta_data( 'wph_retention_anonymized', wp_date( 'Y-m-d' ) );
			$order->save();

			// Lizenzschlüssel sofort leeren, nicht erst nach der Nachprüfung: Bricht der Lauf danach ab, gilt die Bestellung
			// beim nächsten Lauf als anonymisiert und würde übersprungen, der Schlüssel bliebe sonst für immer gefüllt.
			if ( $has_fslm ) {
				$keys_empty += (int) $wpdb->query( $wpdb->prepare( "UPDATE {$fslm_t} SET owner_first_name = '', owner_last_name = '', owner_email_address = '' WHERE order_id = %d", $id ) );
			}

			// Analytics-Kundenzeile nur, wenn die Person keine weitere nicht anonymisierte Bestellung hat.
			if ( $lookup_cb && $has_stats ) {
				$cid = (int) $wpdb->get_var( $wpdb->prepare( "SELECT customer_id FROM {$stats_t} WHERE order_id = %d", $id ) );
				if ( $cid ) {
					$others = (int) $wpdb->get_var(
						$wpdb->prepare(
							"SELECT COUNT(*) FROM {$stats_t} s LEFT JOIN {$m} am ON am.order_id = s.order_id AND am.meta_key = '_anonymized' AND am.meta_value = 'yes'
							WHERE s.customer_id = %d AND s.order_id <> %d AND s.parent_id = 0 AND am.id IS NULL",
							$cid,
							$id
						)
					);
					if ( 0 === $others ) {
						call_user_func( $lookup_cb[0], $order );
						$lookups++;
					}
				}
			}

			// Nachprüfung direkt in der Datenbank (nicht über das Objekt): nichts vom Alten übrig?
			$left  = $extra_keys ? (int) $wpdb->get_var( $wpdb->prepare( "SELECT COUNT(*) FROM {$m} WHERE order_id = %d AND meta_key IN ({$kph})", array_merge( array( $id ), $extra_keys ) ) ) : 0;
			$flat  = $wpdb->get_row( $wpdb->prepare( "SELECT billing_email, ip_address, user_agent FROM {$o} WHERE id = %d", $id ), ARRAY_A );
			$addr  = (string) $wpdb->get_var( $wpdb->prepare( "SELECT email FROM {$addr_t} WHERE order_id = %d AND address_type = 'billing'", $id ) );
			$index = (string) $wpdb->get_var( $wpdb->prepare( "SELECT meta_value FROM {$m} WHERE order_id = %d AND meta_key = '_billing_address_index'", $id ) );
			// WooCommerce anonymisiert IP (Endstelle 0) und Browserkennung ("[deleted]") statt sie zu leeren; beides gilt als erledigt.
			$ip_ok = ( '' === $ip0 ) || in_array( (string) ( $flat['ip_address'] ?? '' ), array( '', wp_privacy_anonymize_data( 'ip', $ip0 ) ), true );
			$ua_ok = ( '' === $ua0 ) || in_array( (string) ( $flat['user_agent'] ?? '' ), array( '', wp_privacy_anonymize_data( 'text', $ua0 ) ), true );
			$ok    = ( 0 === $left ) && $ip_ok && $ua_ok;
			if ( '' !== $email && 0 !== stripos( $email, 'deleted@' ) ) {
				$ok = $ok
					&& 0 !== strcasecmp( (string) ( $flat['billing_email'] ?? '' ), $email )
					&& 0 !== strcasecmp( $addr, $email )
					&& false === stripos( $index, $email );
			}
			if ( ! $ok ) {
				$verify_fail++;
				break 2; // systematischer Fehler: sofort stoppen
			}
			$done_ids[] = $id;
		} catch ( Throwable $e ) {
			$errors++;
			if ( $errors >= 10 ) {
				break 2;
			}
		}
	}
	$done += count( $done_ids );
}

echo "Anonymisiert: {$done} Bestellungen, {$keys_empty} Lizenzschlüssel geleert, {$lookups} Analytics-Kundenzeilen anonymisiert.\n";
echo "Fehler: {$errors}, fehlgeschlagene Nachprüfungen: {$verify_fail}\n";
if ( $errors || $verify_fail ) {
	exit( 1 );
}
