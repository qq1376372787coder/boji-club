<?php
declare(strict_types=1);
/** Shared SQL importer for the real empty-database CLI and isolated fixtures. */
function bojiSchemaStatements(string $sql): array {
    $parts=[]; $buffer=''; $quote=null; $length=strlen($sql);
    for($i=0;$i<$length;$i++) {
        $char=$sql[$i]; $next=$sql[$i+1]??'';
        if($quote!==null) {
            $buffer.=$char;
            if($char==='\\' && $next!=='') { $buffer.=$next; $i++; }
            elseif($char===$quote) {
                if($next===$quote) { $buffer.=$next; $i++; } else $quote=null;
            }
        } elseif(($char==='-' && $next==='-' && preg_match('/\s/', $sql[$i+2]??' ')) || $char==='#') {
            while($i<$length && $sql[$i]!=="\n")$i++; $buffer.="\n";
        } elseif($char==='/' && $next==='*') {
            $end=strpos($sql,'*/',$i+2); if($end===false)throw new RuntimeException('Unclosed SQL comment');
            $i=$end+1; $buffer.=' ';
        } elseif(in_array($char,["'",'"','`'],true)) { $quote=$char; $buffer.=$char; }
        elseif($char===';') { if(trim($buffer)!=='')$parts[]=trim($buffer); $buffer=''; }
        else $buffer.=$char;
    }
    if($quote!==null)throw new RuntimeException('Unclosed SQL quote');
    if(trim($buffer)!=='')$parts[]=trim($buffer);
    return $parts;
}
function bojiApplySchema(PDO $db, string $root): int {
    $count=0;
    foreach(['schema.sql','admin-schema.sql','sync-schema-v59.sql','migrations/20261026-onboarding-v2.sql','migrations/20261026-member-feedback128.sql','migrations/20261028-ai-context-schema.sql','migrations/20261028-scheduled-notifications.sql','migrations/20261028-subscription-ops.sql'] as $file) {
        $sql=file_get_contents($root.'/'.$file);
        if($sql===false)throw new RuntimeException('Missing schema '.$file);
        foreach(bojiSchemaStatements($sql) as $statement) {
            $conditional=(bool)preg_match('/^ALTER TABLE\s+\S+\s+ADD\s+(?:COLUMN|UNIQUE KEY|KEY|INDEX) IF NOT EXISTS\b/i',$statement);
            $statement=preg_replace('/\bADD (COLUMN|UNIQUE KEY|KEY|INDEX) IF NOT EXISTS\b/i','ADD $1',$statement);
            try {$db->exec($statement); $count++;}
            catch(PDOException $error) {
                // Only explicitly conditional duplicate columns/indexes are no-ops.
                if(!$conditional || !in_array((int)($error->errorInfo[1]??0),[1060,1061],true))throw $error;
            }
        }
    }
    return $count;
}
