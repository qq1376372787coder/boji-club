<?php
declare(strict_types=1);
require $argv[1].'/account-server/public/club-artwork.php';
$folder=sys_get_temp_dir().'/boji-v23-artwork-'.bin2hex(random_bytes(8));mkdir($folder);
$checks=0;
function check(bool $condition,string $name): void { global $checks;if(!$condition)throw new RuntimeException($name);$checks++; }
function metadataRequest(string $name,string $directory): array {
    global $argv;
    $code='require '.var_export($argv[1].'/account-server/public/club-artwork.php',true).';echo json_encode(clubArtworkMetadata('.var_export($name,true).','.var_export($directory,true).'));';
    $output=shell_exec(escapeshellarg(PHP_BINARY).' -r '.escapeshellarg($code));
    return json_decode((string)$output,true,512,JSON_THROW_ON_ERROR);
}
try {
    $name='club-keepsake-01-test-v20.png';$full=$folder.'/'.$name;$thumb=$folder.'/club-keepsake-01-test-v20-thumb.png';
    file_put_contents($full,'first-image');file_put_contents($thumb,'thumbnail');touch($full,100);touch($thumb,200);
    $meta=metadataRequest($name,$folder);
    check($meta['image_sha256']===hash('sha256','first-image'),'full checksum is content based');
    check($meta['thumbnail_sha256']===hash('sha256','thumbnail'),'thumbnail has its own checksum');
    check(strlen($meta['image_version'])===64,'version is an explicit content-derived field');
    check(clubArtworkVersionMatches($meta,$meta['image_version']),'current version allowed');
    check(!clubArtworkVersionMatches($meta,str_repeat('0',64)),'outdated version rejected');
    check(clubArtworkVersionMatches($meta,null),'legacy clients without version supported');
    file_put_contents($full,'other-image');touch($full,100);
    $changed=metadataRequest($name,$folder);
    check($changed['image_version']!==$meta['image_version'],'same filename size and timestamp content replacement changes version');
    file_put_contents($thumb,'new-thumb');touch($thumb,200);
    $newThumb=metadataRequest($name,$folder);
    check($newThumb['image_version']!==$changed['image_version'],'thumbnail-only update changes version');
    touch($full,300);clearstatcache();$stale=metadataRequest($name,$folder);
    check($stale['thumbnail_sha256']===$stale['image_sha256'],'stale thumbnail falls back to current full artwork');
    unlink($thumb);clearstatcache();$noThumb=metadataRequest($name,$folder);
    check($noThumb['thumbnail_sha256']===$noThumb['image_sha256'],'missing thumbnail safely uses full artwork');
    check(clubArtworkFiles('../outside.png',$folder)===null,'path traversal rejected');
    check(clubArtworkFiles('a\\b.png',$folder)===null,'Windows separator rejected');
    check(clubArtworkFiles('missing.png',$folder)===null,'missing image gives no file');
    check(clubArtworkMetadata(null,$folder)['image_version']===null,'absent image remains optional');
    $outside=$folder.'-outside.png';file_put_contents($outside,'outside');symlink($outside,$folder.'/link.png');
    check(clubArtworkFiles('link.png',$folder)===null,'symlink outside media folder rejected');
    unlink($folder.'/link.png');unlink($outside);
    check(clubArtworkMetadata('missing.png',$folder)['image_sha256']===null,'missing content has no invented checksum');
    echo "PASS $checks v23 PHP artwork checks\n";
} finally { foreach(glob($folder.'/*')?:[] as $file)unlink($file);rmdir($folder); }
