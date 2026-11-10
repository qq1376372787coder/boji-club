<?php
declare(strict_types=1);
// Apple private keys and the encryption key must live outside public/. Never log tokens.
function appleTokensConfigured(array $config): bool {
    return !empty($config['apple_team_id']) && !empty($config['apple_key_id'])
        && is_string($config['apple_private_key_path'] ?? null) && is_readable($config['apple_private_key_path'])
        && strlen(base64_decode((string)($config['apple_token_encryption_key'] ?? ''),true) ?: '')===32;
}
function appleB64(string $value): string { return rtrim(strtr(base64_encode($value),'+/','-_'),'='); }
function appleES256Signature(string $der): string {
    $offset=0;
    $length=static function() use(&$offset,$der): int {
        if($offset>=strlen($der)) throw new RuntimeException('apple_signature');
        $n=ord($der[$offset++]); if($n<128)return $n;
        $bytes=$n&127; if($bytes<1 || $bytes>2 || $offset+$bytes>strlen($der))throw new RuntimeException('apple_signature');
        $n=0;for($i=0;$i<$bytes;$i++)$n=($n<<8)|ord($der[$offset++]);return $n;
    };
    if(ord($der[$offset++])!==48)throw new RuntimeException('apple_signature');$length();$raw='';
    for($i=0;$i<2;$i++) {
        if(ord($der[$offset++])!==2)throw new RuntimeException('apple_signature');$n=$length();
        $v=ltrim(substr($der,$offset,$n),"\0");$offset+=$n;
        if(strlen($v)>32)throw new RuntimeException('apple_signature');$raw.=str_pad($v,32,"\0",STR_PAD_LEFT);
    }
    return $raw;
}
function appleClientSecret(array $config,string $clientID): string {
    if(!appleTokensConfigured($config))throw new RuntimeException('apple_configuration');
    $now=time();$header=appleB64(json_encode(['alg'=>'ES256','kid'=>$config['apple_key_id']],JSON_THROW_ON_ERROR));
    $claims=appleB64(json_encode(['iss'=>$config['apple_team_id'],'iat'=>$now,'exp'=>$now+300,'aud'=>'https://appleid.apple.com','sub'=>$clientID],JSON_THROW_ON_ERROR));
    $key=openssl_pkey_get_private(file_get_contents($config['apple_private_key_path']));
    if(!$key || !openssl_sign($header.'.'.$claims,$signature,$key,OPENSSL_ALGO_SHA256))throw new RuntimeException('apple_signature');
    return $header.'.'.$claims.'.'.appleB64(appleES256Signature($signature));
}
function appleTokenSeal(string $value,array $config): string {
    $key=base64_decode((string)$config['apple_token_encryption_key'],true);if(strlen($key ?: '')!==32)throw new RuntimeException('apple_configuration');
    $iv=random_bytes(12);$cipher=openssl_encrypt($value,'aes-256-gcm',$key,OPENSSL_RAW_DATA,$iv,$tag,'BojiClubAppleToken',16);
    if($cipher===false)throw new RuntimeException('apple_token_storage');return base64_encode($iv.$tag.$cipher);
}
function appleTokenOpen(string $value,array $config): string {
    $key=base64_decode((string)($config['apple_token_encryption_key'] ?? ''),true);$raw=base64_decode($value,true);
    if(strlen($key ?: '')!==32 || strlen($raw ?: '')<29)throw new RuntimeException('apple_token_storage');
    $plain=openssl_decrypt(substr($raw,28),'aes-256-gcm',$key,OPENSSL_RAW_DATA,substr($raw,0,12),substr($raw,12,16),'BojiClubAppleToken');
    if(!is_string($plain))throw new RuntimeException('apple_token_storage');return $plain;
}
function appleTokenHTTP(string $endpoint,array $form): array {
    if(!in_array($endpoint,['token','revoke'],true))throw new RuntimeException('apple_endpoint');
    $context=stream_context_create(['http'=>['method'=>'POST','header'=>"Content-Type: application/x-www-form-urlencoded\r\n",'content'=>http_build_query($form),'timeout'=>10,'ignore_errors'=>true,'follow_location'=>0]]);
    $raw=@file_get_contents('https://appleid.apple.com/auth/'.$endpoint,false,$context);$status=0;
    foreach($http_response_header ?? [] as $line)if(preg_match('#^HTTP/\S+ (\d{3})#',$line,$m))$status=(int)$m[1];
    $result=json_decode(is_string($raw)?$raw:'',true);
    return [$status,is_array($result)?$result:[]];
}
function appleAuthorizationTokens(array $config,array $input,string $subject): ?array {
    if(!appleTokensConfigured($config))return null; // Older accounts still have the manual revocation flow.
    $code=$input['authorization_code'] ?? null;
    if(!is_string($code) || strlen($code)<10 || strlen($code)>4096)throw new RuntimeException('apple_authorization_code');
    $parts=explode('.',(string)$input['identity_token']);$claims=json_decode(base64urlDecode($parts[1] ?? '') ?: '',true);
    $aud=$claims['aud'] ?? ''; $clients=$config['apple_client_ids'] ?? [];$clients=is_array($clients)?$clients:[$clients];
    if(!is_string($aud) || !in_array($aud,$clients,true))throw new RuntimeException('apple_client');
    [$status,$value]=appleTokenHTTP('token',['client_id'=>$aud,'client_secret'=>appleClientSecret($config,$aud),'code'=>$code,'grant_type'=>'authorization_code']);
    if($status!==200 || !is_string($value['refresh_token'] ?? null))throw new RuntimeException('apple_exchange');
    // This ID token comes directly from Apple's HTTPS token endpoint. Bind it to the verified login.
    $idParts=explode('.',(string)($value['id_token'] ?? ''));$id=json_decode(base64urlDecode($idParts[1] ?? '') ?: '',true);
    if(($id['sub'] ?? '')!==$subject || ($id['aud'] ?? '')!==$aud || ($id['iss'] ?? '')!=='https://appleid.apple.com' || ($id['exp'] ?? 0)<=time())throw new RuntimeException('apple_exchange_identity');
    return ['client_id'=>$aud,'token_cipher'=>appleTokenSeal($value['refresh_token'],$config)];
}
function appleRevokeStoredTokens(PDO $db,array $config,int $userID): void {
    $q=$db->prepare('SELECT client_id,token_cipher FROM apple_tokens WHERE user_id=?');$q->execute([$userID]);$row=$q->fetch();
    if(!$row)return;
    [$status]=appleTokenHTTP('revoke',['client_id'=>$row['client_id'],'client_secret'=>appleClientSecret($config,$row['client_id']),'token'=>appleTokenOpen($row['token_cipher'],$config),'token_type_hint'=>'refresh_token']);
    if($status!==200)throw new RuntimeException('apple_revocation');
    $db->prepare('DELETE FROM apple_tokens WHERE user_id=?')->execute([$userID]);
}

function appleRefreshStoredTokens(PDO $db,array $config): void {
    if(!appleTokensConfigured($config))return;
    $rows=$db->query("SELECT t.* FROM apple_tokens t JOIN users u ON u.id=t.user_id WHERE u.status='active' AND t.checked_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY) LIMIT 5")->fetchAll();
    foreach($rows as $row) {
        // Refresh at most once per day. A temporary Apple failure never revokes a valid app session.
        $claim=$db->prepare('UPDATE apple_tokens SET checked_at=UTC_TIMESTAMP() WHERE user_id=? AND token_cipher=? AND checked_at=?');
        $claim->execute([$row['user_id'],$row['token_cipher'],$row['checked_at']]);if(!$claim->rowCount())continue;
        try {
            [$status,$value]=appleTokenHTTP('token',['client_id'=>$row['client_id'],'client_secret'=>appleClientSecret($config,$row['client_id']),'grant_type'=>'refresh_token','refresh_token'=>appleTokenOpen($row['token_cipher'],$config)]);
            if($status===400 && ($value['error'] ?? '')==='invalid_grant') {
                $db->beginTransaction();
                $db->prepare('SELECT id FROM users WHERE id=? FOR UPDATE')->execute([$row['user_id']]);
                $q=$db->prepare('SELECT token_cipher FROM apple_tokens WHERE user_id=? FOR UPDATE');$q->execute([$row['user_id']]);
                if($q->fetchColumn()===$row['token_cipher']) {
                    $db->prepare('DELETE FROM sessions WHERE user_id=?')->execute([$row['user_id']]);
                    $db->prepare('DELETE FROM apple_tokens WHERE user_id=?')->execute([$row['user_id']]);
                }
                $db->commit();
            } elseif($status===200 && is_string($value['refresh_token'] ?? null)) {
                $db->prepare('UPDATE apple_tokens SET token_cipher=? WHERE user_id=? AND token_cipher=?')->execute([appleTokenSeal($value['refresh_token'],$config),$row['user_id'],$row['token_cipher']]);
            }
        } catch(Throwable) { if($db->inTransaction())$db->rollBack(); error_log('Apple token refresh deferred'); }
    }
}
