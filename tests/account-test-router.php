<?php
if (str_starts_with(parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH),'/admin/')) require __DIR__.'/../account-server/admin/index.php';
else require __DIR__.'/../account-server/public/index.php';
