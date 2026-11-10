<?php
declare(strict_types=1);
require __DIR__.'/../account-server/public/cloud-validation.php';

$checks = 0;
function fail(string $message, int $status = 400): void { throw new RuntimeException($message); }
function check109(bool $ok, string $message, string $field = 'state'): void {
    global $checks;
    if (!$ok) throw new RuntimeException($message);
    $checks++;
}
function rejects109(mixed $value, mixed $shape, string $field = 'state'): bool {
    try { cloudValidate($value, $shape, $field); return false; }
    catch (RuntimeException $error) { return true; }
}

// 自由计划：28 天、逐组参数与动作边界必须逐层校验。
$movement = [
    'id'=>'11111111-1111-1111-1111-111111111111','name'=>'哑铃卧推','muscle'=>'胸',
    'query'=>'dumbbell bench press','libraryID'=>'sample','unit'=>'次','count'=>3,
    'weight'=>10,'reps'=>12,'seconds'=>30,'restSeconds'=>90,
    'individualSets'=>[['weight'=>10,'reps'=>12],['weight'=>10,'reps'=>10],['weight'=>10,'reps'=>8]],
];
$days = array_fill(0, 28, ['title'=>'', 'movements'=>[]]);
$days[0] = ['title'=>'胸肩', 'movements'=>[$movement], 'placeholder'=>true];
$draft = ['version'=>1,'id'=>'22222222-2222-2222-2222-222222222222','title'=>'Build 109',
    'start'=>'2026-10-19','duration'=>7,'days'=>$days,'planDescription'=>'八周增肌',
    'planIntent'=>'稳定训练','planPatternLabel'=>'练二练一休'];
check109(rejects109($draft, 'planDraft') === false, 'valid nested plan draft passes schema');
check109(cloudPlanDraftValid($draft), 'valid nested plan draft passes semantic bounds');
$badDays = $days; $badDays[0]['movements'][0]['unit'] = '小时';
check109(rejects109(['days'=>$badDays] + $draft, 'planDraft'), 'unknown movement unit rejected at schema level');
$short = $draft; $short['days'] = array_slice($days, 0, 27);
check109(!cloudPlanDraftValid($short), 'draft must contain exactly 28 day slots');
$tooMany = $days; $tooMany[0]['movements'] = array_fill(0, 61, $movement);
check109(!cloudPlanDraftValid(['days'=>$tooMany] + $draft), 'movement count above the draft limit rejected');
$badSet = $days; $badSet[0]['movements'][0]['individualSets'][0]['reps'] = 1001;
check109(!cloudPlanDraftValid(['days'=>$badSet] + $draft), 'out-of-range individual set target rejected');

// 阶段报告：趋势点必须落在报告区间内。
$report = ['id'=>'phase/2026-09-01/2026-09-28/x','start'=>'2026-09-01','end'=>'2026-09-28',
    'generatedAt'=>1,'daysCovered'=>10,'daysTotal'=>28,'trainingDaysPlanned'=>3,
    'trainingDaysCompleted'=>3,'confirmedSets'=>9,'measuredDays'=>2,
    'trends'=>[['identity'=>'library/bench','name'=>'卧推','unit'=>'reps','weight'=>20,
        'points'=>[['date'=>'2026-09-02','value'=>20,'sets'=>2],['date'=>'2026-09-09','value'=>22,'sets'=>2]],
        'sampleCount'=>2,'spanDays'=>7,'verdict'=>'登记表现上升','detail'=>'依据登记。']],
    'hasPreviousPhase'=>false,'summary'=>'小结','notes'=>[],'evidenceDigest'=>'abc123'];
check109(cloudPhaseReportsValid(['days'=>['2026-09-28'=>['phaseReports'=>[$report]]]]), 'valid phase report passes');
$outside = $report; $outside['trends'][0]['points'][0]['date'] = '2026-08-31';
check109(!cloudPhaseReportsValid(['days'=>['2026-09-28'=>['phaseReports'=>[$outside]]]]), 'trend point outside interval rejected');
$badCount = $report; $badCount['trends'][0]['sampleCount'] = 5;
check109(!cloudPhaseReportsValid(['days'=>['2026-09-28'=>['phaseReports'=>[$badCount]]]]), 'trend sample count cannot exceed points');
$badMeasure = $report; $badMeasure['measuredDays'] = 99;
check109(!cloudPhaseReportsValid(['days'=>['2026-09-28'=>['phaseReports'=>[$badMeasure]]]]), 'covered/measured days cannot exceed interval');

// Club AI 日程提案：只接受有限的 from→to 意图，基线由服务端提供。
$proposal = ['version'=>1,'moves'=>[['from'=>'2026-10-20','to'=>'2026-10-22']],
    'baseline'=>[['date'=>'2026-10-20','label'=>'胸','exercises'=>[$movement]]]];
check109(cloudScheduleProposalsValid(['aiJobs'=>[['result'=>['coach'=>['schedule_proposal'=>$proposal]]]]]), 'valid schedule proposal passes');
$foreign = $proposal; $foreign['moves'] = [['from'=>'2026-10-20','to'=>'2026-10-20']];
check109(!cloudScheduleProposalsValid(['aiJobs'=>[['result'=>['coach'=>['schedule_proposal'=>$foreign]]]]]), 'from==to rejected');
$duplicate = $proposal; $duplicate['moves'] = [['from'=>'2026-10-20','to'=>'2026-10-22'],['from'=>'2026-10-21','to'=>'2026-10-22']];
check109(!cloudScheduleProposalsValid(['aiJobs'=>[['result'=>['coach'=>['schedule_proposal'=>$duplicate]]]]]), 'duplicate target rejected');
$tooManyMoves = $proposal; $tooManyMoves['moves'] = array_fill(0, 8, ['from'=>'2026-10-20','to'=>'2026-10-22']);
check109(!cloudScheduleProposalsValid(['aiJobs'=>[['result'=>['coach'=>['schedule_proposal'=>$tooManyMoves]]]]]), 'more than seven moves rejected');

// 旧版顺延遗留的越界周期标记：服务端修复归属但不删除训练记录。
$legacy = ['days'=>[
    '2026-10-13'=>['exercises'=>[['id'=>'33333333-3333-3333-3333-333333333333']],'meals'=>[],
        'planCycle'=>['start'=>'2026-10-05','endDate'=>'2026-10-11','plannedDates'=>['2026-10-13']]],
    '2026-10-20'=>['exercises'=>[],'meals'=>[],
        'planCycle'=>['start'=>'2026-10-19','endDate'=>'2026-10-25','plannedDates'=>['2026-10-20','2026-10-20','2026-10-27']]],
]];
$normalized = cloudNormalizeCycleOwnership($legacy);
check109(!isset($normalized['days']['2026-10-13']['planCycle']), 'cycle marker outside its interval removed');
check109($normalized['days']['2026-10-13']['exercises'] !== [], 'normalization never deletes training data');
check109($normalized['days']['2026-10-20']['planCycle']['plannedDates'] === ['2026-10-20'], 'planned dates deduplicated and bounded');

// 行动状态包括用户拒绝；旧值仍兼容。
check109(rejects109('rejected', 'actionStateValue') === false, 'rejected is a valid action state');
check109(rejects109('reference', 'actionStateValue') === false, 'legacy reference state remains valid');
check109(rejects109('maybe', 'actionStateValue'), 'unknown action state rejected');


// 分块提交只带 meta（没有 days）时也必须能通过结构/语义校验。
$meta = ['version'=>1,'profile'=>['nickname'=>'测试','age'=>28,'height'=>175.0,'weight'=>68.0,
    'goal'=>'增肌','experience'=>'新手','venue'=>'健身房','daysPerWeek'=>3,'focus'=>'全身'],
    'drafts'=>[],'importedPlan'=>'','planDrafts'=>[],'planTemplates'=>[]];
check109(rejects109($meta,'state') === false, 'meta-only state passes schema without days');
check109(cloudExperienceValid($meta), 'meta-only semantic validation passes');

echo "PASS {$checks} Build 109 cloud schema and semantic validation checks\n";
