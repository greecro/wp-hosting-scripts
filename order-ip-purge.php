<?php
/**
 * IP-Adresse und Browserkennung in Bestellungen nach Fristablauf leeren.
 *
 * Aufruf (durch order-ip-purge.sh, als Site-User):
 *   wp eval-file order-ip-purge.php <apply|dry> <tage> <batch> <nur-ids|->
 *
 * Gelöscht wird die Kennung (Chargeback-Fenster: Frist ab Bestelldatum), nicht die Bestellung:
 *   - Bestelltabelle (HPOS): Spalten ip_address und user_agent werden geleert.
 *   - Meta-Felder mit derselben Information (Standardliste unten, per Filter
 *     wph_order_ip_purge_meta_keys erweiterbar) werden gelöscht.
 *
 * Direktes SQL statt WC_Order::save(): save() würde date_modified setzen und für jede Bestellung
 * Analytics- und Sync-Aufgaben (Action Scheduler) auslösen. Die Cache-Schichten von WooCommerce (Bestelldaten,
 * Bestellobjekt, Meta) werden je Bestellung über deren eigene Methoden geleert und im Echtlauf an einer
 * Stichprobe über die WooCommerce-API gegengeprüft (Abbruch, wenn dort noch Werte erscheinen).
 *
 * Ohne "apply" wird nichts geschrieben. Ausgabe und Protokoll enthalten nur Zahlen, nie Personendaten.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

global $wpdb;

$mode  = ( ( $args[0] ?? 'dry' ) === 'apply' ) ? 'apply' : 'dry';
$days  = (int) ( $args[1] ?? 120 );
$batch = (int) ( $args[2] ?? 500 );
$only  = array();
if ( ( $args[3] ?? '-' ) !== '-' ) {
	$only = array_values( array_unique( array_filter( array_map( 'intval', explode( ',', (string) $args[3] ) ) ) ) );
	if ( ! $only ) {
		WP_CLI::error( 'Ungültige Liste bei --only-ids.' );
	}
}
if ( $days < 1 || $days > 3650 ) {
	WP_CLI::error( 'Frist in Tagen muss zwischen 1 und 3650 liegen.' );
}
if ( $batch < 10 || $batch > 2000 ) {
	WP_CLI::error( 'Batch-Größe muss zwischen 10 und 2000 liegen.' );
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

$o      = $wpdb->prefix . 'wc_orders';
$m      = $wpdb->prefix . 'wc_orders_meta';
$cutoff = gmdate( 'Y-m-d H:i:s', time() - $days * DAY_IN_SECONDS );

// Felder, die IP oder Browserkennung zusätzlich zu den Spalten tragen (Funde auf best4software.com):
// Altname der WooCommerce-Meta, Order Attribution (Browserkennung), Matomo-Plugin (IP und Browserkennung).
$keys = apply_filters(
	'wph_order_ip_purge_meta_keys',
	array(
		'_customer_ip_address',
		'_customer_user_agent',
		'_wc_order_attribution_user_agent',
		'_piwik_ipaddress',
		'_piwik_useragent',
	)
);
$keys = array_values( array_unique( array_filter( array_map( 'strval', (array) $keys ) ) ) );
$kph  = implode( ',', array_fill( 0, count( $keys ), '%s' ) );

$only_sql = $only ? ' AND o.id IN (' . implode( ',', $only ) . ')' : '';
$has_data = "(o.ip_address <> '' OR o.user_agent <> '' OR EXISTS (SELECT 1 FROM {$m} mm WHERE mm.order_id = o.id AND mm.meta_key IN ({$kph}) AND mm.meta_value <> ''))";

// --- Zählung (immer) --------------------------------------------------------------------------------------

$stat = $wpdb->get_row(
	$wpdb->prepare(
		"SELECT COUNT(*) AS total,
			COALESCE(SUM(o.date_created_gmt < %s), 0) AS aelter,
			COALESCE(SUM(o.date_created_gmt < %s AND o.ip_address <> ''), 0) AS ip,
			COALESCE(SUM(o.date_created_gmt < %s AND o.user_agent <> ''), 0) AS ua,
			COALESCE(SUM(o.date_created_gmt >= %s AND (o.ip_address <> '' OR o.user_agent <> '')), 0) AS juenger_mit_daten
		FROM {$o} o WHERE o.type = 'shop_order'{$only_sql}",
		$cutoff,
		$cutoff,
		$cutoff,
		$cutoff
	),
	ARRAY_A
);

$meta_counts = array();
foreach ( (array) $wpdb->get_results(
	$wpdb->prepare(
		"SELECT mm.meta_key AS k, COUNT(*) AS n FROM {$m} mm JOIN {$o} o ON o.id = mm.order_id
		WHERE o.type = 'shop_order' AND o.date_created_gmt < %s AND mm.meta_value <> '' AND mm.meta_key IN ({$kph}){$only_sql}
		GROUP BY mm.meta_key ORDER BY mm.meta_key",
		array_merge( array( $cutoff ), $keys )
	),
	ARRAY_A
) as $row ) {
	$meta_counts[ $row['k'] ] = (int) $row['n'];
}

$todo_from = "FROM {$o} o WHERE o.type = 'shop_order' AND o.date_created_gmt < %s AND {$has_data}{$only_sql}";
$todo_args = array_merge( array( $cutoff ), $keys );
$todo      = (int) $wpdb->get_var( $wpdb->prepare( "SELECT COUNT(*) {$todo_from}", $todo_args ) );

echo 'Frist: ' . $days . ' Tage ab Bestelldatum (Bestellungen vor ' . $cutoff . " GMT)\n";
echo 'Bestellungen gesamt: ' . (int) $stat['total'] . "\n";
echo 'Älter als die Frist: ' . (int) $stat['aelter'] . "\n";
echo '  mit IP-Adresse: ' . (int) $stat['ip'] . "\n";
echo '  mit Browserkennung: ' . (int) $stat['ua'] . "\n";
foreach ( $keys as $k ) {
	echo '  Meta ' . $k . ': ' . ( $meta_counts[ $k ] ?? 0 ) . "\n";
}
echo 'Zu leeren (Bestellungen mit mindestens einer Kennung): ' . $todo . "\n";
echo 'Noch nicht fällig, aber mit Kennung: ' . (int) $stat['juenger_mit_daten'] . "\n";

if ( 'apply' !== $mode ) {
	echo "Trockenlauf: nichts geschrieben.\n";
	return;
}

// --- Echtlauf ----------------------------------------------------------------------------------------------

// Cache-Schichten von WooCommerce: Bestelldaten (clear_cached_data), Bestellobjekt (OrderCache), Meta-Cache.
// Fehlt eine, wird nicht geschrieben, damit nirgends veraltete Werte stehen bleiben.
$store = class_exists( '\Automattic\WooCommerce\Internal\DataStores\Orders\OrdersTableDataStore' ) ? wc_get_container()->get( \Automattic\WooCommerce\Internal\DataStores\Orders\OrdersTableDataStore::class ) : null;
$cache = class_exists( '\Automattic\WooCommerce\Caches\OrderCache' ) ? wc_get_container()->get( \Automattic\WooCommerce\Caches\OrderCache::class ) : null;
if ( ! $store || ! method_exists( $store, 'clear_cached_data' ) || ! $cache || ! method_exists( $cache, 'remove' ) ) {
	WP_CLI::error( 'Cache-Schnittstellen von WooCommerce nicht gefunden. Abbruch, damit keine veralteten Werte im Cache bleiben.' );
}

$changed    = 0;
$meta_rows  = 0;
$rounds_max = (int) ceil( max( 1, $todo ) / $batch ) + 3;

for ( $round = 0; $round < $rounds_max; $round++ ) {
	$ids = $wpdb->get_col( $wpdb->prepare( "SELECT o.id {$todo_from} ORDER BY o.id LIMIT %d", array_merge( $todo_args, array( $batch ) ) ) );
	if ( ! $ids ) {
		break;
	}
	$ids = array_map( 'intval', $ids );
	$in  = implode( ',', $ids );

	// Vorab-Prüfung: Jede gewählte ID muss alle Kriterien wirklich erfüllen (und bei --only-ids in der Liste stehen),
	// sonst wird nichts geschrieben. Schützt davor, dass eine fehlerhafte Auswahl fremde Bestellungen trifft.
	$ok_count = (int) $wpdb->get_var( $wpdb->prepare( "SELECT COUNT(*) {$todo_from} AND o.id IN ({$in})", $todo_args ) );
	if ( $ok_count !== count( $ids ) || min( $ids ) < 1 || ( $only && array_diff( $ids, $only ) ) ) {
		WP_CLI::error( 'Vorab-Prüfung fehlgeschlagen: Die Auswahl erfüllt nicht alle Kriterien. Nichts geschrieben.' );
	}

	if ( false === $wpdb->query( "UPDATE {$o} SET ip_address = '', user_agent = '' WHERE type = 'shop_order' AND id IN ({$in})" ) ) {
		WP_CLI::error( 'UPDATE auf wc_orders fehlgeschlagen.' );
	}
	$deleted = $wpdb->query( $wpdb->prepare( "DELETE FROM {$m} WHERE order_id IN ({$in}) AND meta_key IN ({$kph})", $keys ) );
	if ( false === $deleted ) {
		WP_CLI::error( 'DELETE auf wc_orders_meta fehlgeschlagen.' );
	}
	$meta_rows += (int) $deleted;

	$store->clear_cached_data( $ids );
	foreach ( $ids as $id ) {
		$cache->remove( $id );
		wp_cache_delete( WC_Order::generate_meta_cache_key( $id, 'orders' ), 'orders' );
	}

	// Gegenprobe über die WooCommerce-API: sieht sie die Änderung (Cache wirklich geleert)?
	foreach ( array( $ids[0], $ids[ count( $ids ) - 1 ] ) as $probe ) {
		$order = wc_get_order( $probe );
		if ( ! $order || '' !== (string) $order->get_customer_ip_address( 'edit' ) || '' !== (string) $order->get_customer_user_agent( 'edit' ) ) {
			WP_CLI::error( 'Gegenprobe fehlgeschlagen: WooCommerce liefert nach dem Leeren noch Werte. Abbruch.' );
		}
		foreach ( $keys as $k ) {
			if ( '' !== (string) $order->get_meta( $k, true, 'edit' ) ) {
				WP_CLI::error( 'Gegenprobe fehlgeschlagen: Meta-Feld nach dem Löschen noch vorhanden. Abbruch.' );
			}
		}
	}
	$changed += count( $ids );
}

$rest = (int) $wpdb->get_var( $wpdb->prepare( "SELECT COUNT(*) {$todo_from}", $todo_args ) );
echo 'Geleert: ' . $changed . ' Bestellungen, ' . $meta_rows . " Meta-Zeilen gelöscht.\n";
echo 'Danach noch zu leeren: ' . $rest . "\n";
if ( $rest > 0 ) {
	exit( 1 );
}
