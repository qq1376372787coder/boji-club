<?php
// Merge into /opt/bojiclub-account/config.php. Do not commit real keys.
return [
 'apple_team_id'=>'',
 'apple_key_id'=>'',
 'apple_private_key_path'=>'/etc/bojiclub/apple-signin.p8',
 // Base64 encoded 32 random bytes, with a secure backup. Changing it makes old tokens unreadable.
 'apple_token_encryption_key'=>'',
];
