<?php
declare(strict_types=1);

const FB128_IMAGE_BYTES=3145728;
const FB128_VIDEO_BYTES=20971520;
const FB128_OWNER_BYTES=314572800;
function fbError128(string $text,int $status=422):never{throw new RuntimeException($text,$status);}
function fbID128(mixed $id):string{if(!is_string($id)||!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/D',$id))fbError128('反馈编号不正确。');return $id;}
function fbUUID128():string{$h=bin2hex(random_bytes(16));return substr($h,0,8).'-'.substr($h,8,4).'-4'.substr($h,13,3).'-a'.substr($h,17,3).'-'.substr($h,20);}
function fbQuery128(PDO $db,string $sql,array $args=[]):PDOStatement{$q=$db->prepare($sql);$q->execute($args);return $q;}
function fbRoot128(int $owner):string{return ($GLOBALS['feedback_media_root128']??dirname(__DIR__).'/media').'/'.$owner.'/feedback128';}
function fbPath128(array $row):string{
 $name=$row['storage_name'];if(!preg_match('/^[0-9a-f-]{36}\.(jpg|mp4)$/D',$name))fbError128('附件不可用。',404);
 return fbRoot128((int)$row['user_id']).'/'.$name;
}
function fbAttachment128(array $a):array{return ['id'=>$a['id'],'kind'=>$a['kind'],'mime'=>$a['mime'],'bytes'=>(int)$a['byte_size'],'duration_seconds'=>$a['duration_seconds']===null?null:(float)$a['duration_seconds']];}
function fbLock128(PDO $db,int $owner):void{if(!fbQuery128($db,"SELECT id FROM users WHERE id=? AND status='active' FOR UPDATE",[$owner])->fetchColumn())fbError128('账号当前不可提交反馈。',403);}
function fbText128(mixed $value):string{
 if(!is_string($value)||!mb_check_encoding($value,'UTF-8'))fbError128('请填写有效的文字。');
 $text=trim($value);if(mb_strlen($text)>4000||str_contains($text,"\0"))fbError128('反馈文字最多 4000 字。');return $text;
}
function fbInput128(array $body):array{
 $text=fbText128($body['text']??'');$ids=$body['attachments']??[];
 if(!is_array($ids)||!array_is_list($ids)||count($ids)>4)fbError128('每条反馈最多添加 4 个附件。');
 $ids=array_map('fbID128',$ids);if(count(array_unique($ids))!==count($ids))fbError128('附件不能重复。');
 if($text===''&&!$ids)fbError128('请填写文字或添加照片、视频。');
 return [$text,$ids];
}
function fbMetadata128(mixed $raw):array{
 if(!is_array($raw))return [];$out=[];
 foreach(['app_version','build','os_version','device_family'] as $key){$v=$raw[$key]??null;if(is_string($v))$out[$key]=mb_substr(trim($v),0,80);}
 return $out;
}
function fbHash128(array $values):string{return hash('sha256',json_encode($values,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR));}
function fbTicket128(PDO $db,int $owner,string $id,bool $lock=false):array{
 $row=fbQuery128($db,'SELECT * FROM member_feedback_tickets WHERE id=? AND user_id=?'.($lock?' FOR UPDATE':''),[fbID128($id),$owner])->fetch();
 if(!$row)fbError128('这条反馈不存在或不属于当前账号。',404);return $row;
}
function fbSummary128(array $r):array{return ['id'=>$r['id'],'category'=>$r['category'],'status'=>$r['status'],'title'=>$r['title'],'last_message_id'=>(int)$r['last_message_id'],'unread'=>(int)($r['last_admin_id']??0)>(int)$r['user_read_id'],'created_at'=>str_replace(' ','T',$r['created_at']).'Z','updated_at'=>str_replace(' ','T',$r['updated_at']).'Z'];}
function fbList128(PDO $db,int $owner,int $page):array{
 $page=max(1,min(100000,$page));$offset=($page-1)*20;
 $rows=fbQuery128($db,"SELECT t.*,(SELECT MAX(m.id) FROM member_feedback_messages m WHERE m.ticket_id=t.id AND m.author='admin') last_admin_id FROM member_feedback_tickets t WHERE t.user_id=? ORDER BY t.updated_at DESC,t.id DESC LIMIT 21 OFFSET $offset",[$owner])->fetchAll();
 return ['items'=>array_map('fbSummary128',array_slice($rows,0,20)),'has_more'=>count($rows)>20];
}
function fbDetail128(PDO $db,int $owner,string $id,int $before=0):array{
 $row=fbTicket128($db,$owner,$id);
 $sql='SELECT * FROM member_feedback_messages WHERE ticket_id=?';$args=[$id];if($before>0){$sql.=' AND id<?';$args[]=$before;}
 $messages=fbQuery128($db,$sql.' ORDER BY id DESC LIMIT 51',$args)->fetchAll();$more=count($messages)>50;$messages=array_reverse(array_slice($messages,0,50));
 foreach($messages as &$m){$media=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE message_id=? ORDER BY id',[$m['id']])->fetchAll();$m=['id'=>(int)$m['id'],'client_id'=>$m['client_id'],'author'=>$m['author'],'text'=>$m['body'],'created_at'=>str_replace(' ','T',$m['created_at']).'Z','attachments'=>array_map('fbAttachment128',$media)];}unset($m);
 $row['last_admin_id']=fbQuery128($db,"SELECT MAX(id) FROM member_feedback_messages WHERE ticket_id=? AND author='admin'",[$id])->fetchColumn();
 return ['ticket'=>fbSummary128($row),'messages'=>$messages,'has_older'=>$more];
}
function fbWrite128(PDO $db,int $owner,string $ticket,array $input,?int $admin=null):array{
 $ticket=fbID128($ticket);$client=fbID128($input['client_id']??null);[$text,$ids]=fbInput128($input);$isNew=($input['new']??false)===true;
 if($admin!==null&&($ids||$isNew))fbError128('后台回复仅支持文字。');
 $category=$input['category']??'problem';if(!in_array($category,['problem','suggestion','other'],true))fbError128('请选择反馈类型。');
 $meta=fbMetadata128($input['metadata']??[]);$author=$admin===null?'member':'admin';
 $hash=fbHash128([$author,$admin,$text,$ids,$isNew,$isNew?$category:null,$isNew?$meta:null,$admin!==null?($input['expected_last_message_id']??null):null]);
 $db->beginTransaction();try{
  fbLock128($db,$owner);
  $r=fbQuery128($db,'SELECT * FROM member_feedback_tickets WHERE id=? FOR UPDATE',[$ticket])->fetch();
  if($r&&(int)$r['user_id']!==$owner)fbError128('反馈编号不可用。',409);
  if(!$r&&!$isNew)fbError128('反馈不存在。',404);
  if($r){$old=fbQuery128($db,'SELECT id,request_hash FROM member_feedback_messages WHERE ticket_id=? AND client_id=?',[$ticket,$client])->fetch();
   if($old){if(!hash_equals($old['request_hash'],$hash))fbError128('同一提交编号已用于不同内容，请核对历史反馈。',409);$db->commit();return fbDetail128($db,$owner,$ticket);}
   if($isNew)fbError128('这条反馈已经提交，请从详情继续补充。',409);
   if($admin!==null&&(int)($input['expected_last_message_id']??-1)!==(int)$r['last_message_id'])fbError128('用户已有新消息，请刷新详情后再回复。原回复文字仍保留。',409);
  }
  if($admin===null){
   $n=fbQuery128($db,"SELECT COUNT(*) FROM member_feedback_messages m JOIN member_feedback_tickets t ON t.id=m.ticket_id WHERE t.user_id=? AND m.author='member' AND m.created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY)",[$owner])->fetchColumn();if((int)$n>=100)fbError128('今天提交较多，请稍后再试。',429);
   if(!$r&&(int)fbQuery128($db,'SELECT COUNT(*) FROM member_feedback_tickets WHERE user_id=? AND created_at>=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY)',[$owner])->fetchColumn()>=20)fbError128('今天的新反馈较多，请在已有反馈中补充。',429);
  }
  $attachments=[];foreach($ids as $media){$a=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE id=? AND user_id=? FOR UPDATE',[$media,$owner])->fetch();if(!$a||$a['message_id']!==null||!is_file(fbPath128($a)))fbError128('附件未上传完成或已用于其他反馈，请重试。',409);$attachments[]=$a;}
  if(!$r){$title=mb_substr(preg_replace('/\s+/u',' ',$text),0,80);if($title==='')$title='照片或视频反馈';fbQuery128($db,"INSERT INTO member_feedback_tickets(id,user_id,category,status,title,metadata_json,created_at,updated_at) VALUES(?,?,?,'open',?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP())",[$ticket,$owner,$category,$title,json_encode($meta,JSON_THROW_ON_ERROR)]);}
  fbQuery128($db,'INSERT INTO member_feedback_messages(ticket_id,client_id,author,admin_id,body,request_hash,created_at) VALUES(?,?,?,?,?,?,UTC_TIMESTAMP())',[$ticket,$client,$author,$admin,$text,$hash]);$message=(int)$db->lastInsertId();
  foreach($ids as $media)fbQuery128($db,'UPDATE member_feedback_attachments SET message_id=? WHERE id=? AND user_id=? AND message_id IS NULL',[$message,$media,$owner]);
  fbQuery128($db,'UPDATE member_feedback_tickets SET status=?,last_message_id=?,updated_at=UTC_TIMESTAMP() WHERE id=?',[$admin===null?'open':'replied',$message,$ticket]);
  if($admin!==null&&function_exists('audit'))audit('reply_member_feedback',$owner,'反馈 '.$ticket.'，回复编号 '.$message);
  $db->commit();return fbDetail128($db,$owner,$ticket);
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
}
function fbMarkRead128(PDO $db,int $owner,string $id,int $message):void{
 fbTicket128($db,$owner,$id);$max=(int)fbQuery128($db,'SELECT MAX(id) FROM member_feedback_messages WHERE ticket_id=? AND id<=?',[$id,$message])->fetchColumn();
 fbQuery128($db,'UPDATE member_feedback_tickets SET user_read_id=GREATEST(user_read_id,?) WHERE id=? AND user_id=?',[$max,$id,$owner]);
}
function fbRun128(array $command,int $timeout=25):string{
 $out=tempnam(sys_get_temp_dir(),'fb128-out-');$err=tempnam(sys_get_temp_dir(),'fb128-err-');$process=null;
 try{$process=proc_open($command,[0=>['file','/dev/null','r'],1=>['file',$out,'w'],2=>['file',$err,'w']],$pipes,null,null,['bypass_shell'=>true]);if(!is_resource($process))fbError128('附件处理服务暂不可用。',503);
  $deadline=microtime(true)+$timeout;do{$state=proc_get_status($process);if(!$state['running'])break;if(microtime(true)>$deadline){proc_terminate($process,9);fbError128('附件处理超时，请换一个较短的视频。');}usleep(20000);}while(true);
  $code=$state['exitcode'];proc_close($process);$process=null;if($code!==0)fbError128('附件无法读取，请重新选择。');if(filesize($out)>1000000)fbError128('附件信息过多。');return (string)file_get_contents($out);
 }finally{if(is_resource($process)){proc_terminate($process,9);proc_close($process);}@unlink($out);@unlink($err);}
}
/** Decode/re-encode pictures and remux a tightly bounded H.264/AAC MP4; never trust the filename. */
function fbNormalize128(string $input,string $mime,string $output):array{
 $size=filesize($input);if($size<50||$size>($mime==='image/jpeg'?FB128_IMAGE_BYTES:FB128_VIDEO_BYTES))fbError128('照片限 3 MB，视频限 20 MB。',413);
 $detected=(new finfo(FILEINFO_MIME_TYPE))->file($input);
 if($mime==='image/jpeg'){
  if($detected!=='image/jpeg')fbError128('照片格式不正确。');$info=@getimagesize($input);if(!$info||$info[0]>2400||$info[1]>2400||$info[0]*$info[1]>6000000)fbError128('照片尺寸过大。');
  if(!function_exists('imagecreatefromjpeg'))fbError128('图片处理服务暂不可用。',503);
  $image=@imagecreatefromjpeg($input);if(!$image)fbError128('照片无法解码。');try{if(!imagejpeg($image,$output,88))fbError128('照片保存失败。',503);}finally{imagedestroy($image);}return ['kind'=>'image','duration'=>null];
 }
 if($mime!=='video/mp4'||!in_array($detected,['video/mp4','application/mp4'],true))fbError128('视频请使用 MP4 格式。');
 if(!is_executable('/usr/bin/ffprobe')||!is_executable('/usr/bin/ffmpeg'))fbError128('视频处理服务暂不可用。',503);
 $probe=json_decode(fbRun128(['/usr/bin/ffprobe','-v','error','-protocol_whitelist','file,pipe','-f','mov','-enable_drefs','0','-show_entries','format=duration:stream=codec_type,codec_name,width,height','-of','json',$input],12),true);
 $duration=(float)($probe['format']['duration']??0);if(!is_finite($duration)||$duration<=0||$duration>60.25)fbError128('视频请控制在 60 秒以内。');
 $video=0;$audio=0;foreach($probe['streams']??[] as $s){if($s['codec_type']==='video'){++$video;if($s['codec_name']!=='h264'||$s['width']>1920||$s['height']>1920)fbError128('视频请压缩为 720p H.264 格式。');}elseif($s['codec_type']==='audio'){++$audio;if($s['codec_name']!=='aac')fbError128('视频音轨格式不支持。');}else fbError128('视频含不支持的数据轨道。');}
 if($video!==1||$audio>1)fbError128('视频轨道不支持。');
 fbRun128(['/usr/bin/ffmpeg','-nostdin','-v','error','-y','-protocol_whitelist','file,pipe','-f','mov','-enable_drefs','0','-i',$input,'-map','0:v:0','-map','0:a:0?','-c','copy','-map_metadata','-1','-map_chapters','-1','-movflags','+faststart','-f','mp4',$output]);
 return ['kind'=>'video','duration'=>$duration];
}
function fbPrune128(PDO $db,int $owner):void{
 $rows=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE user_id=? AND message_id IS NULL AND created_at<DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 DAY)',[$owner])->fetchAll();
 foreach($rows as $r){fbQuery128($db,'DELETE FROM member_feedback_attachments WHERE id=? AND user_id=? AND message_id IS NULL',[$r['id'],$owner]);@unlink(fbPath128($r));}
 $root=fbRoot128($owner);
 foreach(is_dir($root)?new DirectoryIterator($root):[] as $file){
  if(!$file->isFile()||$file->isLink()||$file->getMTime()>=time()-86400)continue;
  $name=$file->getFilename();
  if(str_starts_with($name,'.upload-')){@unlink($file->getPathname());continue;}
  if(preg_match('/^([0-9a-f-]{36})\.(jpg|mp4)$/D',$name,$m)&&!fbQuery128($db,'SELECT 1 FROM member_feedback_attachments WHERE id=? AND user_id=?',[$m[1],$owner])->fetchColumn())@unlink($file->getPathname());
 }

}
function fbUpload128(PDO $db,int $owner,string $id,string $mime,string $hash,string $input):array{
 fbID128($id);if(!preg_match('/^[0-9a-f]{64}$/D',$hash)||!hash_equals($hash,hash_file('sha256',$input)))fbError128('附件校验失败。');
 if(!in_array($mime,['image/jpeg','video/mp4'],true))fbError128('不支持此附件格式。');
 $old=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE id=?',[$id])->fetch();if($old){if((int)$old['user_id']!==$owner)fbError128('附件不可用。',404);if(!hash_equals($old['original_sha256'],$hash)||$old['mime']!==$mime)fbError128('同一附件编号不能用于不同内容。',409);if(is_file(fbPath128($old)))return fbAttachment128($old);}
 $dir=fbRoot128($owner);if(!is_dir($dir)&&!mkdir($dir,0750,true)&&!is_dir($dir))fbError128('附件目录暂不可用。',503);
 if(disk_free_space($dir)<536870912)fbError128('附件空间暂不足，请稍后再试。',503);
 $stage=tempnam($dir,'.upload-');$final=null;
 try{$meta=fbNormalize128($input,$mime,$stage);$bytes=filesize($stage);if($bytes>($meta['kind']==='image'?FB128_IMAGE_BYTES:FB128_VIDEO_BYTES))fbError128('处理后的附件过大。',413);
  $db->beginTransaction();fbLock128($db,$owner);fbPrune128($db,$owner);
  $old=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE id=? FOR UPDATE',[$id])->fetch();
  if($old&&((int)$old['user_id']!==$owner||$old['original_sha256']!==$hash))fbError128('附件编号冲突。',409);
  if($old&&is_file(fbPath128($old))){$db->commit();return fbAttachment128($old);}
  $used=(int)fbQuery128($db,'SELECT COALESCE(SUM(byte_size),0) FROM member_feedback_attachments WHERE user_id=?',[$owner])->fetchColumn();
  if($used+$bytes>FB128_OWNER_BYTES)fbError128('反馈附件空间已达上限，请先提交文字反馈。',413);
  if((int)fbQuery128($db,'SELECT COUNT(*) FROM member_feedback_attachments WHERE user_id=? AND message_id IS NULL',[$owner])->fetchColumn()>=16)fbError128('待提交附件较多，请先处理已有反馈。',429);
  $name=$id.($meta['kind']==='image'?'.jpg':'.mp4');$final=$dir.'/'.$name;chmod($stage,0640);if(!rename($stage,$final))fbError128('附件保存失败。',503);
  if($old)fbQuery128($db,'DELETE FROM member_feedback_attachments WHERE id=?',[$id]);
  fbQuery128($db,'INSERT INTO member_feedback_attachments(id,user_id,kind,mime,storage_name,original_sha256,content_sha256,byte_size,duration_seconds,created_at) VALUES(?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())',[$id,$owner,$meta['kind'],$mime,$name,$hash,hash_file('sha256',$final),$bytes,$meta['duration']]);
  $db->commit();$final=null;return fbAttachment128(fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE id=?',[$id])->fetch());
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();if($final!==null)@unlink($final);throw $e;}finally{@unlink($stage);}
}
function fbMedia128(PDO $db,string $id,?int $owner):array{
 $a=fbQuery128($db,'SELECT a.* FROM member_feedback_attachments a JOIN member_feedback_messages m ON m.id=a.message_id JOIN member_feedback_tickets t ON t.id=m.ticket_id WHERE a.id=?'.($owner!==null?' AND a.user_id=? AND t.user_id=?':''),$owner!==null?[fbID128($id),$owner,$owner]:[fbID128($id)])->fetch();if(!$a||!is_file(fbPath128($a)))fbError128('附件不存在。',404);return $a;
}
function fbServe128(array $row):never{
 $path=fbPath128($row);$size=filesize($path);$start=0;$end=$size-1;$range=$_SERVER['HTTP_RANGE']??'';
 if($range!==''){
  if(!preg_match('/^bytes=(\d*)-(\d*)$/D',$range,$m)||($m[1]===''&&$m[2]==='')){http_response_code(416);header('Content-Range: bytes */'.$size);exit;}
  if($m[1]===''){$n=(int)$m[2];$start=max(0,$size-$n);}else{$start=(int)$m[1];if($m[2]!=='')$end=min($end,(int)$m[2]);}
  if($start>$end||$start>=$size||($m[1]===''&&(int)$m[2]===0)){http_response_code(416);header('Content-Range: bytes */'.$size);exit;}
  http_response_code(206);header("Content-Range: bytes $start-$end/$size");
 }
 header('Content-Type: '.$row['mime']);header('Content-Length: '.($end-$start+1));header('Accept-Ranges: bytes');header('Cache-Control: private, no-store');header('X-Content-Type-Options: nosniff');header('Content-Disposition: inline; filename="feedback.'.($row['kind']==='image'?'jpg':'mp4').'"');
 $stream=fopen($path,'rb');fseek($stream,$start);$left=$end-$start+1;while($left>0&&!feof($stream)&&!connection_aborted()){$data=fread($stream,min(65536,$left));if($data===false||$data==='')break;echo $data;$left-=strlen($data);}fclose($stream);exit;
}
function fbRoute128(PDO $db,array $user,string $method,string $path):never{
 $owner=(int)$user['id'];try{
  if(preg_match('#^/me/feedback/attachments/([0-9a-f-]{36})$#D',$path,$m)){
   $id=fbID128($m[1]);
   if($method==='PUT'){
    $length=(int)($_SERVER['CONTENT_LENGTH']??0);if($length<50||$length>FB128_VIDEO_BYTES)fbError128('附件大小不符合要求。',413);
    $input=tempnam(sys_get_temp_dir(),'fb128-in-');try{$in=fopen('php://input','rb');$out=fopen($input,'wb');$n=stream_copy_to_stream($in,$out,FB128_VIDEO_BYTES+1);fclose($in);fclose($out);if($n!==$length)fbError128('附件上传不完整。');$a=fbUpload128($db,$owner,$id,strtolower(trim(explode(';',$_SERVER['CONTENT_TYPE']??'')[0])),(string)($_SERVER['HTTP_X_CONTENT_SHA256']??''),$input);}finally{@unlink($input);}respond(200,['attachment'=>$a]);
   }
   if($method==='GET')fbServe128(fbMedia128($db,$id,$owner));
   if($method==='DELETE'){
    $db->beginTransaction();fbLock128($db,$owner);$a=fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE id=? AND user_id=? FOR UPDATE',[$id,$owner])->fetch();if($a&&$a['message_id']!==null)fbError128('已提交的附件不可单独移除。',409);if($a)fbQuery128($db,'DELETE FROM member_feedback_attachments WHERE id=? AND user_id=?',[$id,$owner]);$db->commit();if($a)@unlink(fbPath128($a));respond(200,['removed'=>true]);
   }
  }
  if($method==='GET'&&$path==='/me/feedback')respond(200,fbList128($db,$owner,(int)($_GET['page']??1)));
  if(preg_match('#^/me/feedback/([0-9a-f-]{36})(?:/(messages|read))?$#D',$path,$m)){
   $id=fbID128($m[1]);$op=$m[2]??'';
   if($method==='GET'&&$op==='')respond(200,fbDetail128($db,$owner,$id,max(0,(int)($_GET['before']??0))));
   if($method==='POST'&&$op==='read'){$body=body();fbMarkRead128($db,$owner,$id,max(0,(int)($body['message_id']??0)));respond(200,['read'=>true]);}
   if($method==='POST'&&in_array($op,['','messages'],true)){$body=body(30000);$body['new']=$op==='';respond(200,fbWrite128($db,$owner,$id,$body));}
  }
  fbError128('反馈接口不存在。',404);
 }catch(RuntimeException $e){if($db->inTransaction())$db->rollBack();$code=$e->getCode();if($e instanceof PDOException||!in_array($code,[400,403,404,409,413,416,422,429,503],true))throw $e;respond($code,['error'=>$e->getMessage()]);}
}

function feedbackExport128(PDO $db,int $owner):array {
 $items=fbQuery128($db,'SELECT id,category,status,title,created_at,updated_at FROM member_feedback_tickets WHERE user_id=? ORDER BY created_at DESC',[$owner])->fetchAll();
 foreach($items as &$t){$t['messages']=fbQuery128($db,'SELECT id,author,body,created_at FROM member_feedback_messages WHERE ticket_id=? ORDER BY id',[$t['id']])->fetchAll();foreach($t['messages'] as &$m){$m['attachments']=array_map('fbAttachment128',fbQuery128($db,'SELECT * FROM member_feedback_attachments WHERE message_id=? AND user_id=?',[$m['id'],$owner])->fetchAll());}unset($m);}unset($t);return $items;
}
