<?php
/**
 * Logo/Favicon aus dem media-R2-Sync in WordPress uebernehmen.
 *
 * Aufruf: wp eval-file media-import.php <logo-pfad-oder-'-'> <favicon-pfad-oder-'-'>
 * "-" als Platzhalter, wenn die jeweilige Datei nicht vorhanden ist.
 *
 * Logo geht auf den WordPress-Standard-Theme-Mod 'custom_logo' (Blocksy nutzt
 * dafuer kein eigenes Feld, sondern die Core-Site-Identity — im Theme-Quellcode
 * verifiziert, nicht angenommen). Favicon geht auf die Core-Option 'site_icon'.
 */
require_once ABSPATH . 'wp-admin/includes/image.php';
require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/media.php';

$logo_path    = ( ( $args[0] ?? '-' ) === '-' ) ? '' : $args[0];
$favicon_path = ( ( $args[1] ?? '-' ) === '-' ) ? '' : $args[1];

function wph_sideload_image( $path ) {
	if ( empty( $path ) || ! file_exists( $path ) ) {
		return 0;
	}
	if ( preg_match( '/\.svg$/i', $path ) ) {
		// WordPress erlaubt SVG-Uploads standardmaessig nicht (XSS-Risiko bei freien
		// Uploads durch Redakteure). Der Filter gilt nur fuer diesen einen kontrollierten
		// Import aus dem eigenen R2-Bucket, nicht dauerhaft fuer die Media Library.
		add_filter( 'upload_mimes', function ( $mimes ) {
			$mimes['svg'] = 'image/svg+xml';
			return $mimes;
		} );
		add_filter( 'wp_check_filetype_and_ext', function ( $data, $file, $filename ) {
			if ( preg_match( '/\.svg$/i', $filename ) ) {
				$data['ext']  = 'svg';
				$data['type'] = 'image/svg+xml';
			}
			return $data;
		}, 10, 3 );
	}
	$file_array = array(
		'name'     => basename( $path ),
		'tmp_name' => $path,
	);
	$id = media_handle_sideload( $file_array, 0 );
	return is_wp_error( $id ) ? 0 : $id;
}

if ( $logo_path ) {
	$logo_id = wph_sideload_image( $logo_path );
	if ( $logo_id ) {
		set_theme_mod( 'custom_logo', $logo_id );
		echo "logo=ok id={$logo_id}\n";
	} else {
		echo "logo=fail\n";
	}
}

if ( $favicon_path ) {
	$fav_id = wph_sideload_image( $favicon_path );
	if ( $fav_id ) {
		update_option( 'site_icon', $fav_id );
		echo "favicon=ok id={$fav_id}\n";
	} else {
		echo "favicon=fail\n";
	}
}

if ( ! $logo_path && ! $favicon_path ) {
	echo "nothing-to-do\n";
}
