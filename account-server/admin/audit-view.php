<?php
$pg=max(1,min(100000,(int)($_GET['page']??1)));$labels=adminAuditLabels();
$actionFilter=(string)($_GET['operation']??'');if(!isset($labels[$actionFilter]))$actionFilter='';
$search=mb_substr(trim((string)($_GET['q']??'')),0,100);$where=' WHERE 1=1';$args=[];
if($actionFilter!==''){$where.=' AND a.action=?';$args[]=$actionFilter;}
if($search!==''){$where.=' AND (b.username LIKE ? OR a.detail LIKE ? OR CAST(a.target_user_id AS CHAR)=?)';array_push($args,'%'.$search.'%','%'.$search.'%',$search);}
$rows=query('SELECT a.*,b.username FROM admin_audit a LEFT JOIN admin_accounts b ON b.id=a.admin_id'.$where.' ORDER BY a.id DESC LIMIT 21 OFFSET '.(($pg-1)*20),$args)->fetchAll();$more=count($rows)>20;$rows=array_slice($rows,0,20);
?>
<section class="card"><form class="filters" method="get"><input type="hidden" name="p" value="audit"><label>操作类型<select name="operation"><option value="">全部操作</option><?php foreach($labels as $key=>$name):?><option value="<?=h($key)?>" <?=$actionFilter===$key?'selected':''?>><?=h($name)?></option><?php endforeach?></select></label><label>查找记录<input name="q" value="<?=h($search)?>" placeholder="管理员、说明或成员编号"></label><button>搜索</button></form><div class="table-wrap"><table><thead><tr><th>时间</th><th>管理员</th><th>操作</th><th>成员</th><th>说明</th><th>IP</th></tr></thead><tbody><?php foreach($rows as $row):?><tr><td><?=h(stamp($row['created_at']))?></td><td><?=h($row['username']??'未登录')?></td><td><?=h($labels[$row['action']]??$row['action'])?></td><td><?=h($row['target_user_id']?clubNumber((int)$row['target_user_id']):'—')?></td><td><?=h($row['detail'])?></td><td><?=h($row['ip'])?></td></tr><?php endforeach;if(!$rows):?><tr><td colspan="6" class="empty">暂无符合条件的记录</td></tr><?php endif?></tbody></table></div><?php adminPageCount($pg,$more);?></section>
