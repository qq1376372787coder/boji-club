<?php
$health=[];$dbOk=false;$healthError=null;
if($pagePanel==='health'){
 try{$health=aiAdmin('/v1/admin/ai/health');}catch(RuntimeException){$healthError='暂时连不上 AI 服务，请检查服务是否运行。';}
 try{$dbOk=query('SELECT 1')->fetchColumn()==1;}catch(Throwable){$healthError='账号数据库暂时无法连接。';}
}
function adminBackupTime(mixed $value):string{
 if(!is_string($value)||$value==='')return '尚无记录';
 try{return (new DateTimeImmutable($value,new DateTimeZone('UTC')))->setTimezone(new DateTimeZone('Asia/Shanghai'))->format('Y-m-d H:i');}catch(Throwable){return '时间信息待核对';}
}
?>
<?php if($pagePanel==='health'):?>
<?php if($healthError):?><p class="notice is-error" role="alert"><?=h($healthError)?></p><?php endif?>
<div class="metrics"><?php foreach([['账号与记录',$dbOk?'正常':'暂时不可用','负责登录、会员和用户记录。'],['AI 服务',($health['status']??'')==='ok'?'正常':'暂时不可用','负责接收、排队和执行 AI 请求。'],['AI 任务数据',isset($health['database_bytes'])?number_format($health['database_bytes']/1048576,1).' MB':'未读取','这是任务数据库大小，不是照片空间。'],['服务版本',$health['version']??'未读取','用于定位服务器当前运行的版本。']] as [$label,$value,$hint]):?><article><span><?=h($label)?></span><b><?=h($value)?></b><small><?=h($hint)?></small></article><?php endforeach?></div>
<section class="card"><h2>AI 接口配置</h2><p class="muted">这里检查是否已配置接口；实际回复是否正常，请结合 Club AI 的成功率和失败记录查看。</p><div class="table-wrap"><table><thead><tr><th>服务商</th><th>使用的模型</th><th>密钥配置</th></tr></thead><tbody><?php foreach(($health['providers']??[]) as $provider):?><tr><td><?=h($provider['name'])?></td><td><?=h($provider['model'])?></td><td><?=!empty($provider['configured'])?'已配置':'未配置'?></td></tr><?php endforeach;if(empty($health['providers'])):?><tr><td colspan="3" class="empty">暂未读到接口配置</td></tr><?php endif?></tbody></table></div><a class="text-link" href="?p=ai&amp;tab=ai-router-prov">管理模型接口 →</a></section>
<?php else:
$backup=backupStatus();$state=(string)($backup['state']??'unknown');$schedule=$backup['schedule']??[];
$fresh=false;try{$fresh=isset($backup['checked_at'])&&(time()-(new DateTimeImmutable($backup['checked_at']))->getTimestamp())<900;}catch(Throwable){}
$stateLabel=match($state){'running'=>'正在备份','succeeded'=>'最近一次备份成功','failed'=>'最近一次备份失败',default=>'尚未读到备份状态'};
$failures=['dependency_missing'=>'备份程序缺少运行依赖。','password_missing'=>'未配置备份加密密钥。','recovery_path_missing'=>'恢复所需的文件不完整。','ai_database_missing'=>'未找到 AI 任务数据库。','database_dump_failed'=>'数据库导出失败。','archive_missing'=>'最近一次备份文件未找到。','interrupted'=>'备份执行中断，请检查服务器日志。','backup_failed'=>'备份未完成，请检查服务器日志。'];
?>
<section class="card"><div class="section-head"><div><h2>服务器备份</h2><p class="muted">备份账号、记录、图片、AI 数据与服务配置，用于服务器故障后恢复。</p></div><span class="badge <?=$state==='succeeded'&&$fresh?'active':'pending'?>"><?=h($stateLabel)?></span></div>
<?php if(!$backup):?><p class="notice">后台还没有收到备份程序的状态信息，这不代表服务器从未备份。需要先核对备份文件与定时任务。</p><?php elseif(!$fresh):?><p class="notice">备份状态已超过 15 分钟未更新，以下为最后收到的信息。</p><?php endif?>
<?php if($state==='failed'):?><p class="notice is-error"><?=h($failures[$backup['last_error_code']??'']??$failures['backup_failed'])?><?php if(!empty($backup['local_archive_present'])):?> 上一次成功的本机备份仍在。<?php endif?></p><?php endif?>
<div class="profile-grid"><div><small>最近成功备份</small><p><?=h(adminBackupTime($backup['last_success']??null))?></p></div><div><small>最近尝试</small><p><?=h(adminBackupTime($backup['last_attempt']??null))?></p></div><div><small>备份文件</small><p><?=!empty($backup['local_archive_present'])?'已确认文件存在 · '.number_format(((int)($backup['bytes']??0))/1048576,1).' MB':'尚未确认'?></p></div><div><small>下次自动备份</small><p><?=h(adminBackupTime($schedule['next_run_utc']??null))?></p></div></div>
<div class="setting-list"><div class="setting-row"><span><strong>自动备份</strong><small>正常设置为每天北京时间 03:17 起，随机延后最多 5 分钟。</small></span><span><?=empty($schedule['available'])?'尚未确认':(!empty($schedule['active'])&&!empty($schedule['enabled'])?'已开启':'未开启')?></span></div><div class="setting-row"><span><strong>本机备份</strong><small>加密保存在当前服务器，保留最近 14 份。</small></span><span><?=!empty($backup['local_archive_present'])?'有备份':'尚未确认'?></span></div><div class="setting-row"><span><strong>异地副本</strong><small>当前仅保留服务器加密备份，未启用异地复制。</small></span><span><?=h(match($backup['offsite_copy']??'pending'){'ok'=>'副本已确认','failed'=>'复制失败',default=>(!empty($backup['offsite_configured'])?'等待复制':'未配置')})?></span></div><div class="setting-row"><span><strong>恢复演练</strong><small>实际验证备份能否还原，与“文件已生成”分开确认。</small></span><span><?=!empty($backup['restore_verified'])?'已完成':'尚未验证'?></span></div></div>
<details class="advanced-settings"><summary>技术信息</summary><p>状态最后更新：<?=h(adminBackupTime($backup['checked_at']??null))?></p><p>加密：<?=!empty($backup['encrypted'])?'AES-256-GCM':'尚未确认'?> · 保留最近 <?=(int)($backup['retention_copies']??14)?> 份</p><p>服务器会每 5 分钟更新此状态。备份密钥和备份文件不通过网页公开。</p></details>
</section>
<?php endif?>
