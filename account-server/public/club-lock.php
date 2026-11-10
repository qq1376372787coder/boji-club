<?php
declare(strict_types=1);
/** Serialize rule edits with enrollment/grants, scoped to this database. */
function clubRulesLock(PDO $db): void {
    $name='bojiclub.club.'.substr(hash('sha256',(string)$db->query('SELECT DATABASE()')->fetchColumn()),0,16);
    $q=$db->prepare('SELECT GET_LOCK(?,5)');$q->execute([$name]);
    if((int)$q->fetchColumn()!==1) throw new RuntimeException('活动正在更新，请稍后重试。');
    $GLOBALS['bojiClubRulesLockName']=$name;
    register_shutdown_function(static function() use($db,$name): void {
        try{$q=$db->prepare('SELECT RELEASE_LOCK(?)');$q->execute([$name]);}catch(Throwable){}
    });
}
function clubRulesUnlock(PDO $db): void {
    $name=$GLOBALS['bojiClubRulesLockName']??null;
    if(!is_string($name)||$name==='')return;
    unset($GLOBALS['bojiClubRulesLockName']);
    try{$q=$db->prepare('SELECT RELEASE_LOCK(?)');$q->execute([$name]);}catch(Throwable){}
}
