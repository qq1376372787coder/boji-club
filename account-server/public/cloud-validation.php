<?php
declare(strict_types=1);

/** Validate the Swift Codable contract before replacing a user's cloud snapshot. */
function cloudSchemas(): array {
    return [
        'insightDestination'=>['type'=>'insightDestinationType','date'=>'date','sessionID?'=>'uuid'],
        'insightEvent'=>['sourceSessionID?'=>'uuid','action?'=>'insightDestination','version'=>'identityVersion','id'=>'insightEventID','date'=>'date','groupID'=>'text','kind'=>'insightKind','recordedAt'=>'timestamp','previousIDs'=>['list'=>'insightEventID'],'state'=>'insightState','evidenceDigest'=>'insightDigest','title'=>'text','detail'=>'text','evidence'=>'text','priority'=>'int','isTodayReminder'=>'bool'],
        'insightFeedback'=>['version'=>'identityVersion','id'=>'insightFeedbackID','date'=>'date','recordedAt'=>'timestamp','kind'=>'insightKind','action'=>'insightAction','eventID?'=>'insightEventID','scope'=>'text','previousIDs'=>['list'=>'insightFeedbackID']],
        'goalVersion'=>['version'=>'identityVersion','id'=>'uuid','recordedAt'=>'timestamp','profile'=>'profile','nutrition'=>'nutrition'],
        'planDayChange'=>['date'=>'date','before'=>['list'=>'planExercise'],'after'=>['list'=>'planExercise'],'retained'=>'bool'],
        'planVersion'=>['changes?'=>['list'=>'planDayChange'],'version'=>'identityVersion','id'=>'text','recordedAt'=>'timestamp','source'=>'planSource','title'=>'text','start'=>'date','duration'=>'planDuration','sessions'=>['list'=>'session'],'requestedProfile'=>'profile','adoptedProfile'=>'profile','nutrition'=>'nutrition','previousIDs'=>['list'=>'text'],'scopeDates'=>['list'=>'date'],'retainedDates'=>['list'=>'date'],'planDescription?'=>'text','planIntent?'=>'text','planPattern?'=>'text','notes?'=>['list'=>'text']],
        'profileFactMeta'=>['sourceKind'=>'factSource','confirmedAt?'=>'text','revision?'=>'int'],
        'profile'=>['factState?'=>['dict'=>'profileFactMeta'],'ageGroup?'=>'ageGroup','equipmentExclusions?'=>['list'=>'text'],'targetWeightKg?'=>'bodyWeightNumber','planDurationDays?'=>'planDuration','dailyActivity?'=>'text','nutritionContext?'=>'text','identityVersion?'=>'identityVersion','avatarID?'=>'avatarID','avatarImage?'=>'avatarImage','nickname'=>'text','age'=>'int','height'=>'number','weight'=>'number','goal'=>'text','experience'=>'text','venue'=>'text','daysPerWeek'=>'int','focus'=>'text','gender?'=>'text','equipment?'=>'text','equipmentOther?'=>'text','sessionMinutes?'=>'int','limitations?'=>'text','trainingDays?'=>['list'=>'weekday'],'homeTrainingDays?'=>['list'=>'weekday']],
        'set'=>['actualEntered?'=>'bool','id'=>'uuid','weight'=>'number','reps'=>'int','completed'=>'bool','durationSeconds?'=>'seconds'],
        'customExercise'=>['id'=>'uuid','name'=>'customName','muscle'=>'customMuscle','equipment'=>'customEquipment','unit'=>'customUnit','updatedAt'=>'timestamp'],
        'exercise'=>['planID?'=>'text','restSeconds?'=>'restSeconds','customExerciseID?'=>'uuid','customUnit?'=>'customUnit','id'=>'uuid','name'=>'text','muscle'=>'text','sets'=>['list'=>'set'],'libraryID?'=>'text','equipment?'=>'text','imageURL?'=>'text','gifURL?'=>'text','libraryQuery?'=>'text','deletedSetIDs?'=>['list'=>'uuid'],'workoutSessionID?'=>'uuid'],
        'component'=>['id'=>'text','name'=>'text','amount'=>'number','unit'=>'text','calories'=>'number','protein'=>'number','carbs'=>'number','fat'=>'number','basis'=>'text','details'=>['list'=>'text'],'sourceKind?'=>'text','sourceRef?'=>'text','sourceDatabase?'=>'text','sourceVersion?'=>'text','confidenceLow?'=>'number','confidenceHigh?'=>'number','edibleGrams?'=>'number','uncertaintyFlags?'=>['list'=>'text'],'requiresReview?'=>'bool','nutritionEngine?'=>'text'],
        'meal'=>['placementConflictDates?'=>['list'=>'date'],'placementConfirmedAt?'=>'timestamp','id'=>'uuid','name'=>'text','category'=>'text','calories'=>'number','protein'=>'number','carbs'=>'number','fat'=>'number','photoFilename?'=>'media','photoRemoteID?'=>'media','sourceAIJobID?'=>'text','estimated?'=>'bool','portion?'=>'text','recognitionConfidence?'=>'number','estimateNotes?'=>['list'=>'text'],'components?'=>['list'=>'component'],'consumedFraction?'=>'number','nutritionKnown?'=>'bool','requiresReview?'=>'bool','nutritionSources?'=>['list'=>'text']],
        'source'=>['id'=>'text','name'=>'text'],
        'metric'=>['recordedAt?'=>'timestamp','value'=>'number','source'=>'source','availableSources?'=>['list'=>'source']],
        'workout'=>['id'=>'text','name'=>'text','start'=>'timestamp','end'=>'timestamp','minutes'=>'number','calories?'=>'number','source'=>'source','activityKind?'=>'text','averageHeartRate?'=>'number'],
        'healthWeightSample'=>['id'=>'uuid','externalID'=>'uuid','date'=>'timestamp','kilograms'=>'bodyWeightNumber','source'=>'source'],
        'health'=>['weightSamples?'=>['list'=>'healthWeightSample'],'deletedWeightSampleIDs?'=>['list'=>'uuid'],'date'=>'date','timeZone'=>'text','updatedAt'=>'timestamp','steps?'=>'metric','activeEnergy?'=>'metric','heartRate?'=>'metric','restingHeartRate?'=>'metric','sleep?'=>'metric','bodyMass?'=>'metric','bodyFatPercentage?'=>'metric','leanBodyMass?'=>'metric','height?'=>'metric','bodyMassIndex?'=>'metric','waistCircumference?'=>'metric','workouts'=>['list'=>'workout']],
        'survey'=>['weight?'=>'number','waist?'=>'number','bodyFat?'=>'number','bodyFatSource'=>'text','fatigue'=>'text','pain'=>'text','difficulty'=>'text','diet'=>'text','notes'=>'text','days'=>'int','trainingDays?'=>['list'=>'weekday']],
        'photo'=>['id'=>'uuid','pose'=>'text','filename'=>'media'],
        'planSet'=>['weight?'=>'number','reps'=>'int','durationSeconds?'=>'seconds'],
        'planExercise'=>['rest_seconds?'=>'restSeconds','custom_id?'=>'uuid','custom_unit?'=>'customUnit','name'=>'text','muscle'=>'text','sets'=>['list'=>'planSet'],'library_query?'=>'text','library_id?'=>'text'],
        'session'=>['date'=>'date','label'=>'text','exercises'=>['list'=>'planExercise']],
        'weeklyResult'=>['kind'=>'text','summary'=>'text','training'=>'text','nutrition'=>'text','recovery'=>'text','appearance'=>'text','photoFeedback'=>['list'=>'text'],'decision'=>'text','reason'=>'text','notes'=>['list'=>'text'],'sessions'=>['list'=>'session']],
        'cycle'=>['start'=>'date','endDate?'=>'date','plannedDates'=>['list'=>'date'],'sourceJobID?'=>'text','explanationVersion?'=>'identityVersion'],
        'mealCompletion'=>['signature'=>'text','updatedAt'=>'timestamp'],
        'weekly'=>['cycle?'=>'cycle','scope?'=>'text','inputFingerprint?'=>'text','id'=>'uuid','date'=>'date','survey'=>'survey','photos'=>['list'=>'photo'],'compareWith?'=>'uuid','jobID?'=>'text','status'=>'text','result?'=>'weeklyResult','baseline'=>['dict'=>['list'=>'exercise']],'applied'=>'bool','updatedAt'=>'timestamp'],
        'bodyWeight'=>['id?'=>'uuid','externalSampleID?'=>'text','sourceBundle?'=>'text','kilograms?'=>'bodyWeightNumber','updatedAt'=>'timestamp','bodyFatPercentage?'=>'bodyFatNumber','waistCircumferenceCM?'=>'waistNumber','recordedAt?'=>'timestamp','source?'=>'measurementSource'],
        'executionTarget'=>['targetRestSeconds?'=>'restSeconds','targetReps?'=>'int','targetWeight?'=>'number','id'=>'uuid','exerciseID'=>'uuid','unit'=>'executionUnit','targetSeconds?'=>'seconds'],
        'executionBaseline'=>['restSeconds?'=>'int','version'=>'identityVersion','capturedAt'=>'timestamp','sets'=>['list'=>'executionTarget']],
        'trainingFeedback'=>['version'=>'identityVersion','status'=>'feedbackStatus','reason'=>'text','evidence'=>['list'=>'text'],'next_step'=>'text'],
        'workoutPause'=>['start'=>'timestamp','end?'=>'timestamp'],
        'workoutSession'=>['pauseIntervals?'=>['list'=>'workoutPause'],'cancelledAt?'=>'timestamp','executionBaseline?'=>'executionBaseline','id'=>'uuid','startedAt?'=>'timestamp','endedAt?'=>'timestamp','savedAt?'=>'timestamp','linkedDeviceWorkoutID?'=>'text'],
        'planLifecycleAction'=>['id'=>'uuid','planID'=>'text','kind'=>'planLifecycleKind','createdAt'=>'timestamp','exerciseIDs'=>['list'=>'uuid'],'clearsCycle?'=>'bool'],
        'day'=>['planActions?'=>['list'=>'planLifecycleAction'],'insightEvents?'=>['list'=>'insightEvent'],'insightFeedback?'=>['list'=>'insightFeedback'],'goalVersions?'=>['list'=>'goalVersion'],'planVersions?'=>['list'=>'planVersion'],'planShifts?'=>['list'=>'planShiftRecord'],'phaseReports?'=>['list'=>'phaseReport'],'movedFromDate?'=>'date','plannedMoveDestination?'=>'date','weeklyReviewHistory?'=>['list'=>'weekly'],'deletedWeeklyReviewIDs?'=>['list'=>'uuid'],'planCycle?'=>'cycle','mealCompletion?'=>'mealCompletion','exercises'=>['list'=>'exercise'],'meals'=>['list'=>'meal'],'health?'=>'health','weeklyReview?'=>'weekly','workoutSavedAt?'=>'timestamp','workoutStartedAt?'=>'timestamp','workoutEndedAt?'=>'timestamp','linkedDeviceWorkoutID?'=>'text','nutritionTarget?'=>'nutrition','bodyWeight?'=>'bodyWeight','bodyMeasurements?'=>['list'=>'bodyWeight'],'deletedBodyMeasurementIDs?'=>['list'=>'uuid'],'workoutSessions?'=>['list'=>'workoutSession'],'activeWorkoutSessionID?'=>'uuid'],
        'draft'=>['id'=>'uuid','text'=>'text','createdAt'=>'timestamp'],
        'nutrition'=>['maintenanceMin?'=>'number','maintenanceMax?'=>'number','strategy?'=>'text','calculationVersion?'=>'int','generalGuidanceOnly?'=>'bool','caloriesMin'=>'number','caloriesMax'=>'number','proteinMin'=>'number','proteinMax'=>'number','fatMin'=>'number','fatMax'=>'number','meals'=>'int','note'=>'text'],
        'request'=>['id'=>'text','kind'=>'text','date'=>'date','payload'=>['dict'=>'json']],
        'batchMeal'=>['id'=>'text','date'=>'date','category'=>'text','name'=>'text','notes'=>['list'=>'text'],'components'=>['list'=>'component'],'estimated'=>'bool','calories'=>'number','protein'=>'number','carbs'=>'number','fat'=>'number'],
        'planReason'=>['id'=>'text','title'=>'text','basis'=>'text','detail'=>'text'],
        'planPurpose'=>['date'=>'date','purpose'=>'text'],
        'planExplanation'=>['version'=>'identityVersion','summary'=>['list'=>'text'],'sections'=>['list'=>'planReason'],'sessions'=>['list'=>'planPurpose']],
        'planShiftRecord'=>['replaced?'=>['dict'=>['list'=>'planExercise']],'sourceCycles?'=>['dict'=>'date'],'effectScope?'=>['list'=>'date'],'reason?'=>'text','id'=>'text','createdAt'=>'timestamp','shiftDays'=>'int','moves'=>['dict'=>'date']],
        'phaseTrendPoint'=>['date'=>'date','value'=>'int','sets'=>'int'],
        'phaseTrend'=>['identity'=>'text','name'=>'text','unit'=>'text','weight?'=>'number','points'=>['list'=>'phaseTrendPoint'],'sampleCount'=>'int','spanDays'=>'int','verdict'=>'text','detail'=>'text'],
        'phaseReport'=>['weightFirstKg?'=>'number','weightLastKg?'=>'number','plateauNote?'=>'text','evidenceDigest?'=>'phaseDigest','id'=>'text','start'=>'date','end'=>'date','generatedAt'=>'timestamp','daysCovered'=>'int','daysTotal'=>'int','trainingDaysPlanned'=>'int','trainingDaysCompleted'=>'int','confirmedSets'=>'int','measuredDays'=>'int','trends'=>['list'=>'phaseTrend'],'hasPreviousPhase'=>'bool','summary'=>'text','notes'=>['list'=>'text']],
        'actionState'=>['note?'=>'text','id'=>'text','state'=>'actionStateValue','updatedAt'=>'timestamp'],
        'planMovement'=>['id'=>'uuid','name'=>'text','muscle'=>'text','query?'=>'text','libraryID?'=>'text','customID?'=>'uuid','unit'=>'customUnit','count'=>'int','weight'=>'number','reps'=>'int','seconds'=>'int','restSeconds?'=>'restSeconds','individualSets?'=>['list'=>'planSet']],
        'planDraftDay'=>['title'=>'text','movements'=>['list'=>'planMovement'],'placeholder?'=>'bool'],
        'planDraft'=>['singleDay?'=>'bool','updatedAt?'=>'timestamp','deleted?'=>'bool','planDescription?'=>'text','planIntent?'=>'text','planPatternLabel?'=>'text','proposalJobID?'=>'text','suggestedForProfile?'=>'profile','version'=>'identityVersion','id'=>'uuid','title'=>'text','start'=>'date','duration'=>'planDuration','days'=>['list'=>'planDraftDay']],
        'weekRecurrence130'=>['enabled'=>'bool','start'=>'date','days'=>['list'=>'planDraftDay']],
        'planTemplate'=>['recurrence130?'=>'weekRecurrence130','updatedAt?'=>'timestamp','deleted?'=>'bool','id'=>'uuid','createdAt'=>'timestamp','draft'=>'planDraft'],
        'coachSource'=>['id'=>'text','date'=>'date','label'=>'text','detail'=>'text'],
        'coachAction'=>['type'=>'coachActionType','date'=>'date'],
        'parameterChange'=>['date'=>'date','exercise'=>'int','set?'=>'int','field'=>'parameterField','value'=>'number','reason'=>'text'],
        'parameterProposal'=>['version'=>'identityVersion','changes'=>['list'=>'parameterChange'],'baseline'=>['list'=>'session']],
        'scheduleMove'=>['from'=>'date','to'=>'date'],
        'scheduleProposal'=>['version'=>'identityVersion','moves'=>['list'=>'scheduleMove'],'baseline'=>['list'=>'session']],
        'coachAnswer'=>['proposal?'=>'parameterProposal','schedule_proposal?'=>'scheduleProposal','purpose?'=>'coachPurpose','source_session?'=>'uuid','answer'=>'text','sources'=>['list'=>'coachSource'],'actions'=>['list'=>'coachAction']],
        'result'=>['plan_description?'=>'text','plan_intent?'=>'text','plan_pattern?'=>'text','coach?'=>'coachAnswer','plan_days?'=>'planDuration','training_feedback?'=>'trainingFeedback','explanation?'=>'planExplanation','kind'=>'text','notes'=>['list'=>'text'],'title?'=>'text','sessions?'=>['list'=>'session'],'name?'=>'text','is_food?'=>'bool','components?'=>['list'=>'component'],'estimated?'=>'bool','calories?'=>'number','protein?'=>'number','carbs?'=>'number','fat?'=>'number','summary?'=>'text','training?'=>'text','nutrition?'=>'text','recovery?'=>'text','meals?'=>['list'=>'batchMeal']],
        'job'=>['id'=>'text','digest'=>'text','request'=>'request','status'=>'text','result?'=>'result','error?'=>'text','provider?'=>'text','model?'=>'text','created'=>'timestamp','consumed'=>'bool','errorCode?'=>'text','replacementID?'=>'text','retryAfter?'=>'timestamp','connectionFailures?'=>'int'],
        'state'=>['actionStates?'=>['list'=>'actionState'],'planDrafts?'=>['list'=>'planDraft'],'planTemplates?'=>['list'=>'planTemplate'],'deletedPlanDraftIDs?'=>['list'=>'uuid'],'deletedPlanTemplateIDs?'=>['list'=>'uuid'],'syncSchemaVersion?'=>'int','emptySessionDeletionVersion?'=>'identityVersion','recordIntegrityVersion?'=>'identityVersion','customExerciseVersion?'=>'identityVersion','customExercises?'=>['list'=>'customExercise'],'deletedCustomExerciseIDs?'=>['list'=>'uuid'],'experienceVersion?'=>'identityVersion','version'=>'int','days?'=>['dict'=>'day'],'profile'=>'profile','drafts'=>['list'=>'draft'],'importedPlan'=>'text','appliedAIJobs?'=>['list'=>'text'],'deletedExerciseIDs?'=>['list'=>'uuid'],'deletedMealIDs?'=>['list'=>'uuid'],'deletedMediaIDs?'=>['list'=>'media'],'deletedAIJobIDs?'=>['list'=>'text'],'nutritionTarget?'=>'nutrition','aiJobs?'=>['list'=>'job']],
    ];
}

function cloudValidate(mixed $value, mixed $shape, string $field='state', int $depth=0): void {
    if($depth>48) fail('同步内容层级过多。',400);
    if(is_string($shape)) {
        if($shape==='set' && is_array($value) && ($value['completed']??false)===true && ($value['actualEntered']??null)===false) fail('请填写实际训练数值后再标记完成。',400);
        $schemas=cloudSchemas();
        if(isset($schemas[$shape])) { cloudValidate($value,$schemas[$shape],$field,$depth+1);return; }
        $valid=match($shape) {
            'factSource'=>is_string($value) && in_array($value,['confirmed','legacy_recorded','unknown','model_candidate','user_input','draft','estimated','measured'],true),
            'ageGroup'=>in_array($value,['adult','minor'],true),
            'insightKind'=>is_string($value) && in_array($value,['training','nutrition','body','workout','plan'],true),
            'actionStateValue'=>is_string($value) && in_array($value,['pending','completed','failed','expired','reference','rejected'],true),
            'parameterField'=>in_array($value,['weight','reps','durationSeconds','rest_seconds'],true),
            'coachPurpose'=>in_array($value,['dialogue','workout','weekly'],true),
            'coachActionType'=>is_string($value) && in_array($value,['training','nutrition','body','plans','daily','weekly','schedule_shift'],true),
            'insightDestinationType'=>is_string($value) && in_array($value,['workout_summary','training','nutrition','body','schedule_shift'],true),
            'insightState'=>is_string($value) && in_array($value,['active','withdrawn','expired'],true),
            'insightAction'=>is_string($value) && in_array($value,['helpful','reduce','normal','dismiss_today','restore_today','read','unread','archive','unarchive'],true),
            'insightDigest'=>is_string($value) && preg_match('/^[0-9a-f]{64}$/D',$value)===1,
            'phaseDigest'=>is_string($value) && preg_match('/^[0-9a-f]{1,64}$/D',$value)===1,
            'insightEventID'=>is_string($value) && preg_match('#^insight/[0-9a-f]{64}$#D',$value)===1,
            'insightFeedbackID'=>is_string($value) && preg_match('#^feedback/[0-9a-f]{64}$#D',$value)===1,
            'planSource'=>is_string($value) && in_array($value,['ai','manual','continuation','weekly_review'],true),
            'planDuration'=>is_int($value) && in_array($value,[7,14,28],true),
            'identityVersion'=>is_int($value) && $value===1,
            'avatarID'=>is_string($value) && preg_match('/^avatar-(0[1-9]|1[0-2])$/D',$value)===1,
            'avatarImage'=>is_string($value) && strlen($value)<=44000 && ($decoded=base64_decode($value,true))!==false && strlen($decoded)<=32768 && str_starts_with($decoded,"\xff\xd8\xff") && ($dimensions=@getimagesizefromstring($decoded))!==false && $dimensions[0]<=256 && $dimensions[1]<=256,
            'customName'=>is_string($value) && mb_strlen($value)<=60 && trim($value)!=='' && !preg_match('/[\x00-\x1F\x7F]/u',$value),
            'customEquipment'=>is_string($value) && mb_strlen($value)<=60,
            'customMuscle'=>is_string($value) && in_array($value,['','胸','背','肩','手臂','大腿','臀','小腿','核心','有氧'],true),
            'customUnit'=>in_array($value,['次','秒'],true),
            'executionUnit'=>in_array($value,['time','reps'],true),
            'feedbackStatus'=>in_array($value,['green','yellow','red','gray'],true),
            'text'=>is_string($value) && mb_strlen($value)<=20000,
            'planLifecycleKind'=>is_string($value) && in_array($value,['ended','archived'],true),
            'bool'=>is_bool($value),
            'int'=>is_int($value) && $value>=0 && $value<=1000000,
            'bodyWeightNumber'=>!is_bool($value) && (is_int($value)||is_float($value)) && is_finite((float)$value) && $value>=20 && $value<=400,
            'bodyFatNumber'=>!is_bool($value) && (is_int($value)||is_float($value)) && is_finite((float)$value) && $value>=0 && $value<=70,
            'waistNumber'=>!is_bool($value) && (is_int($value)||is_float($value)) && is_finite((float)$value) && $value>=30 && $value<=300,
            'measurementSource'=>is_string($value) && in_array($value,['manual'],true),
            'number'=>!is_bool($value) && (is_int($value)||is_float($value)) && is_finite((float)$value) && $value>=0 && $value<=10000000,
            'timestamp'=>!is_bool($value) && (is_int($value)||is_float($value)) && is_finite((float)$value) && $value>=-978307200 && $value<=10000000000,
            'restSeconds'=>is_int($value) && $value>=0 && $value<=3600,
            'seconds'=>is_int($value) && $value>=0 && $value<=21600,
            'weekday'=>is_int($value) && $value>=1 && $value<=7,
            'uuid'=>is_string($value) && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/Di',$value)===1,
            'media'=>is_string($value) && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.jpg$/Di',$value)===1,
            'date'=>is_string($value) && cloudDateValid($value),
            'json'=>true,
            default=>false,
        };
        if(!$valid) fail('同步字段格式不正确：'.$field.'。原云端记录仍保留。',400);
        return;
    }
    if(isset($shape['list'])) {
        if(!is_array($value) || !array_is_list($value) || (count($value)>20000 && !in_array($field,['state.deletedExerciseIDs','state.deletedMealIDs','state.deletedMediaIDs','state.deletedAIJobIDs'],true))) fail('同步列表格式不正确：'.$field.'。',400);
        foreach($value as $i=>$item) cloudValidate($item,$shape['list'],$field.'['.$i.']',$depth+1);
        return;
    }
    if(isset($shape['dict'])) {
        if($value instanceof stdClass) $value=(array)$value;
        if(!is_array($value) || ($value && array_is_list($value))) fail('同步字典格式不正确：'.$field.'。',400);
        foreach($value as $key=>$item) {
            if(!is_string($key) || strlen($key)>200) fail('同步字典标识不正确。',400);
            if($field==='state.days' || str_ends_with($field,'.baseline')) cloudValidate($key,'date',$field.'.date',$depth+1);
            cloudValidate($item,$shape['dict'],$field.'.'.$key,$depth+1);
        }
        return;
    }
    if(!is_array($value) || ($value && array_is_list($value))) fail('同步记录格式不正确：'.$field.'。',400);
    foreach($shape as $raw=>$child) {
        $optional=str_ends_with($raw,'?');$key=rtrim($raw,'?');
        if($optional && (!array_key_exists($key,$value) || $value[$key]===null)) continue;
        if(!array_key_exists($key,$value)) fail('同步记录缺少字段：'.$field.'.'.$key.'。',400);
        cloudValidate($value[$key],$child,$field.'.'.$key,$depth+1);
    }
}

function cloudWorkoutSessionsValid(array $state): bool {
    foreach (($state['days'] ?? []) as $day) {
        $sessions=$day['workoutSessions']??[];
        if(!$sessions) {
            if(isset($day['activeWorkoutSessionID'])) return false;
            foreach($day['exercises'] as $exercise) if(isset($exercise['workoutSessionID'])) return false;
            continue;
        }
        // Retain concurrent device additions even when the App new-session limit is 8.
        if(count($sessions)>64) return false;
        $ids=[];
        foreach($sessions as $session) {
            $id=strtolower($session['id']); if(isset($ids[$id])) return false; $ids[$id]=true;
            if(isset($session['startedAt'],$session['endedAt']) && $session['endedAt']<$session['startedAt']) return false;
            $lastEnd=null;$open=false;
            if(count($session['pauseIntervals']??[])>256)return false;
            foreach($session['pauseIntervals']??[] as $pause){
                if(!isset($session['startedAt']) || $pause['start']<$session['startedAt'] || $open || ($lastEnd!==null && $pause['start']<$lastEnd))return false;
                if(isset($pause['end']) && ($pause['end']<$pause['start'] || (isset($session['endedAt']) && $pause['end']>$session['endedAt'])))return false;
                if(!isset($pause['end']) && isset($session['savedAt']))return false;
                $open=!isset($pause['end']);$lastEnd=$pause['end']??$pause['start'];
            }
        }
        if(!isset($ids[strtolower($day['activeWorkoutSessionID']??'')])) return false;
        foreach($day['exercises'] as $exercise) if(!isset($ids[strtolower($exercise['workoutSessionID']??'')])) return false;
        $completed=[]; $links=[];
        foreach($day['exercises'] as $exercise) foreach($exercise['sets'] as $set) {
            if(!empty($set['completed']) && (isset($set['durationSeconds']) ? $set['durationSeconds']>0 : $set['reps']>0)) $completed[strtolower($exercise['workoutSessionID'])]=true;
        }
        foreach($sessions as $session) {
            $id=strtolower($session['id']);
            if(isset($session['savedAt']) && empty($completed[$id])) return false;
            if(isset($session['executionBaseline'])) {
                $baseline=$session['executionBaseline'];$targets=$baseline['sets'];$seenTargets=[];
                if(!$targets || count($targets)>1500) return false;
                if(isset($session['savedAt']) && $baseline['capturedAt']>$session['savedAt']) return false;
                foreach($targets as $target) {
                    $key=strtolower($target['id']);if(isset($seenTargets[$key]))return false;$seenTargets[$key]=true;
                    if($target['unit']==='time' && (!isset($target['targetSeconds']) || $target['targetSeconds']<1))return false;
                    if($target['unit']==='reps' && isset($target['targetSeconds']))return false;
                }
            }
            if(isset($session['linkedDeviceWorkoutID'])) {
                $link=$session['linkedDeviceWorkoutID'];
                if(empty($completed[$id]) || isset($links[$link])) return false;
                $matches=array_filter($day['health']['workouts']??[],fn($workout)=>$workout['id']===$link);
                if(count($matches)!==1) return false;
                $links[$link]=true;
            }
            if($id===strtolower($day['activeWorkoutSessionID'])) foreach(['startedAt'=>'workoutStartedAt','endedAt'=>'workoutEndedAt','savedAt'=>'workoutSavedAt','linkedDeviceWorkoutID'=>'linkedDeviceWorkoutID'] as $field=>$mirror) {
                if(($session[$field]??null)!=($day[$mirror]??null)) return false;
            }
        }
    }
    return true;
}

function cloudWorkoutSessionsPreserved(array $previous, array $incoming): bool {
    $incomingDays=(array)($incoming['days']??[]);
    foreach(($previous['days']??[]) as $date=>$day) {
        if(empty($day['workoutSessions'])) continue;
        $ids=array_map(fn($session)=>strtolower($session['id']),$day['workoutSessions']);
        $new=array_map(fn($session)=>strtolower($session['id']),$incomingDays[$date]['workoutSessions']??[]);
        $missing=array_diff($ids,$new);
        if(!$missing) continue;
        if(($incoming['emptySessionDeletionVersion']??null)!==1 || count($new)<1) return false;
        foreach($day['workoutSessions'] as $session) {
            $id=strtolower($session['id']);if(!in_array($id,$missing,true))continue;
            foreach(['startedAt','endedAt','savedAt','linkedDeviceWorkoutID','executionBaseline'] as $field) if(isset($session[$field]))return false;
            foreach(array_merge($day['exercises']??[],$incomingDays[$date]['exercises']??[]) as $exercise) {
                if(strtolower($exercise['workoutSessionID']??'')===$id)return false;
            }
        }
    }
    return true;
}

function cloudDateValid(string $value): bool {
    $date=DateTimeImmutable::createFromFormat('!Y-m-d',$value,new DateTimeZone('UTC'));
    return $date!==false && $date->format('Y-m-d')===$value;
}

function cloudPreserveLegacyIdentity(array $incoming,array $previous): array {
    if(($incoming['identityVersion']??null)!==1) {
        foreach(['avatarID','avatarImage','identityVersion'] as $field) {
            if(array_key_exists($field,$previous)) $incoming[$field]=$previous[$field];
            else unset($incoming[$field]);
        }
    }
    return $incoming;
}


function cloudPreserveLegacyExperience(array $incoming, array $previous): array {
    foreach($incoming['days'] as $date=>&$day) {
        $old=[];foreach($previous['days'][$date]['exercises']??[] as $exercise)$old[strtolower($exercise['id'])]=$exercise;
        foreach($day['exercises'] as &$exercise) {
            $before=$old[strtolower($exercise['id'])]??[];
            if(!array_key_exists('restSeconds',$exercise) && array_key_exists('restSeconds',$before))$exercise['restSeconds']=$before['restSeconds'];
        }unset($exercise);
    }unset($day);

    // v36 clients understand experienceVersion but not private exercises.
    if(($incoming['customExerciseVersion']??null)!==1) {
        foreach(['customExercises','deletedCustomExerciseIDs'] as $field) {
            if(array_key_exists($field,$previous)) $incoming[$field]=$previous[$field];
            else unset($incoming[$field]);
        }
        foreach($incoming['days'] as $date=>&$day) {
            $old=[];
            foreach($previous['days'][$date]['exercises']??[] as $exercise) $old[strtolower($exercise['id'])]=$exercise;
            foreach($day['exercises'] as &$exercise) {
                $before=$old[strtolower($exercise['id'])]??[];
                if(isset($before['customExerciseID'])) {
                    $exercise['customExerciseID']=$before['customExerciseID'];
                    $exercise['customUnit']=$before['customUnit'];
                    foreach(['libraryID','libraryQuery','imageURL','gifURL'] as $field) unset($exercise[$field]);
                }
            }
            unset($exercise);
        }
        unset($day);
    }
    if(($incoming['experienceVersion']??null)===1) return $incoming;
    foreach(['dailyActivity','nutritionContext'] as $field) {
        if(!array_key_exists($field,$incoming['profile']) && isset($previous['profile'][$field])) $incoming['profile'][$field]=$previous['profile'][$field];
    }
    if(!isset($incoming['nutritionTarget']) && isset($previous['nutritionTarget'])) $incoming['nutritionTarget']=$previous['nutritionTarget'];
    if(isset($incoming['nutritionTarget'],$previous['nutritionTarget'])) {
        $fields=['maintenanceMin','maintenanceMax','strategy','calculationVersion','generalGuidanceOnly'];
        foreach($fields as $field) if(!array_key_exists($field,$incoming['nutritionTarget']) && array_key_exists($field,$previous['nutritionTarget'])) $incoming['nutritionTarget'][$field]=$previous['nutritionTarget'][$field];
        foreach(['caloriesMin','caloriesMax','proteinMin','proteinMax','fatMin','fatMax'] as $field) {
            if(($incoming['nutritionTarget'][$field]??null)!==($previous['nutritionTarget'][$field]??null)) { $incoming['nutritionTarget']['calculationVersion']=1; break; }
        }
    }
    $special=($incoming['profile']['age']??18)<18 || (($incoming['profile']['nutritionContext']??'普通成人')!=='普通成人');
    if($special && isset($incoming['nutritionTarget'])) $incoming['nutritionTarget']['generalGuidanceOnly']=true;
    foreach($incoming['days'] as $date=>&$day) {
        foreach(['planCycle','mealCompletion'] as $field) {
            if(!array_key_exists($field,$day) && isset($previous['days'][$date][$field])) $day[$field]=$previous['days'][$date][$field];
        }
        if(isset($previous['days'][$date]['nutritionTarget'])) {
            foreach(['maintenanceMin','maintenanceMax','strategy','calculationVersion','generalGuidanceOnly'] as $field) {
                if(isset($day['nutritionTarget']) && !array_key_exists($field,$day['nutritionTarget']) && isset($previous['days'][$date]['nutritionTarget'][$field])) $day['nutritionTarget'][$field]=$previous['days'][$date]['nutritionTarget'][$field];
            }
        }
    }
    unset($day);
    // Do not upgrade the incoming marker: old clients still cannot intentionally clear metadata.
    return $incoming;
}
function cloudPlanDraftValid(array $draft): bool {
    if(mb_strlen((string)($draft['title']??''))>500) return false;
    foreach(['planDescription'=>2000,'planIntent'=>1000,'planPatternLabel'=>2000] as $field=>$max) {
        if(isset($draft[$field]) && (!is_string($draft[$field]) || mb_strlen($draft[$field])>$max)) return false;
    }
    $days=$draft['days']??null;
    if(!is_array($days) || count($days)!==28) return false;
    if(!in_array((int)($draft['duration']??0),[7,14,28],true)) return false;
    foreach($days as $day) {
        if(!is_array($day) || mb_strlen((string)($day['title']??''))>500) return false;
        $movements=$day['movements']??null;
        if(!is_array($movements) || count($movements)>60) return false;
        foreach($movements as $movement) {
            if(!is_array($movement)) return false;
            if(mb_strlen((string)($movement['name']??''))>200 || mb_strlen((string)($movement['muscle']??''))>100) return false;
            if(isset($movement['query']) && (!is_string($movement['query']) || mb_strlen($movement['query'])>500)) return false;
            if(isset($movement['libraryID']) && (!is_string($movement['libraryID']) || mb_strlen($movement['libraryID'])>200)) return false;
            if(isset($movement['customID'],$movement['libraryID'])) return false;
            $count=$movement['count']??0;
            if(!is_int($count) || $count<0 || $count>50) return false;
            $weight=$movement['weight']??0;
            if((!is_int($weight) && !is_float($weight)) || $weight<0 || $weight>2000) return false;
            $reps=$movement['reps']??0;
            if(!is_int($reps) || $reps<0 || $reps>1000) return false;
            $seconds=$movement['seconds']??0;
            if(!is_int($seconds) || $seconds<0 || $seconds>21600) return false;
            if(isset($movement['restSeconds']) && (!is_int($movement['restSeconds']) || $movement['restSeconds']<0 || $movement['restSeconds']>3600)) return false;
            if(isset($movement['individualSets'])) {
                if(!is_array($movement['individualSets']) || count($movement['individualSets'])>50) return false;
                foreach($movement['individualSets'] as $set) {
                    if(!is_array($set)) return false;
                    if(isset($set['weight']) && ((!is_int($set['weight']) && !is_float($set['weight'])) || $set['weight']<0 || $set['weight']>2000)) return false;
                    if(isset($set['reps']) && (!is_int($set['reps']) || $set['reps']<0 || $set['reps']>1000)) return false;
                    if(isset($set['durationSeconds']) && (!is_int($set['durationSeconds']) || $set['durationSeconds']<1 || $set['durationSeconds']>21600)) return false;
                }
            }
        }
    }
    return true;
}
function cloudPlanDraftsValid(array $state): bool {
    foreach($state['planDrafts']??[] as $draft) {
        if(($draft['deleted']??false)===true) continue;
        if(!is_array($draft) || !cloudPlanDraftValid($draft)) return false;
    }
    foreach($state['planTemplates']??[] as $template) {
        if(($template['deleted']??false)===true) continue;
        if(!is_array($template['draft']??null) || !cloudPlanDraftValid($template['draft'])) return false;
        if(isset($template['recurrence130'])) {
            $r=$template['recurrence130'];
            if(!is_array($r)||!is_bool($r['enabled']??null)||!preg_match('/^\d{4}-\d{2}-\d{2}$/D',(string)($r['start']??''))||count($r['days']??[])!==7)return false;
            $probe=$template['draft'];$probe['days']=array_merge($r['days'],$r['days'],$r['days'],$r['days']);
            if(!cloudPlanDraftValid($probe))return false;
        }
    }
    return true;
}
function cloudPhaseReportValid(array $report): bool {
    $start=$report['start'];$end=$report['end'];$total=$report['daysTotal'];
    if($end<$start || $total<1) return false;
    if($report['daysCovered']>$total || $report['measuredDays']>$total
       || $report['trainingDaysPlanned']>$total || $report['trainingDaysCompleted']>$total) return false;
    foreach($report['trends'] as $trend) {
        if(count($trend['points'])>1000 || $trend['sampleCount']>1000 || $trend['spanDays']>3650) return false;
        if($trend['sampleCount']!==count($trend['points'])) return false;
        if(isset($trend['weight']) && ($trend['weight']<0 || $trend['weight']>2000)) return false;
        foreach($trend['points'] as $point) if($point['date']<$start || $point['date']>$end) return false;
    }
    return true;
}
function cloudPhaseReportsValid(array $state): bool {
    foreach(($state['days']??[]) as $day) foreach($day['phaseReports']??[] as $report) if(!cloudPhaseReportValid($report)) return false;
    return true;
}
function cloudScheduleProposalsValid(array $state): bool {
    foreach(($state['aiJobs']??[]) as $job) {
        $proposal=$job['result']['coach']['schedule_proposal']??null;
        if($proposal===null) continue;
        $moves=$proposal['moves'];
        if(count($moves)<1 || count($moves)>7) return false;
        $from=[];$to=[];
        foreach($moves as $move) {
            if($move['from']===$move['to'] || isset($from[$move['from']]) || isset($to[$move['to']])) return false;
            $from[$move['from']]=true;$to[$move['to']]=true;
        }
        $baseline=$proposal['baseline']??[];
        if(!is_array($baseline) || count($baseline)>7) return false;
        foreach($baseline as $session) {
            $exercises=is_array($session)?($session['exercises']??[]):[];
            if(!is_array($exercises) || count($exercises)>30) return false;
            foreach($exercises as $exercise) {
                $sets=is_array($exercise)?($exercise['sets']??[]):[];
                if(!is_array($sets) || count($sets)>50) return false;
            }
        }
    }
    return true;
}
function cloudDayExperienceValid(string $key, array $day): bool {
    foreach($day['exercises'] as $exercise) {
        if(isset($exercise['customExerciseID'])!==isset($exercise['customUnit'])) return false;
        if(isset($exercise['customExerciseID'])) {
            foreach(['libraryID','libraryQuery','imageURL','gifURL'] as $field) if(isset($exercise[$field])) return false;
        }
    }
    foreach(array_merge($day['weeklyReviewHistory']??[],isset($day['weeklyReview'])?[$day['weeklyReview']]:[]) as $review) if($review['date']!==$key) return false;
    if(isset($day['planCycle'])) {
        $cycle=$day['planCycle']; $start=new DateTimeImmutable($cycle['start']); $maximum=$start->modify('+6 days')->format('Y-m-d'); $end=$cycle['endDate']??$maximum;
        if($end<$cycle['start'] || $end>$maximum) return false;
        if($key<$cycle['start'] || $key>$end || count($cycle['plannedDates'])>7 || count(array_unique($cycle['plannedDates']))!==count($cycle['plannedDates'])) return false;
        foreach($cycle['plannedDates'] as $date) if($date<$cycle['start'] || $date>$end) return false;
    }
    foreach($day['phaseReports']??[] as $report) if(!cloudPhaseReportValid($report)) return false;
    return !isset($day['mealCompletion']) || preg_match('/^[0-9a-f]{1,16}$/D',$day['mealCompletion']['signature'])===1;
}
function cloudCustomExercisesValid(array $state): bool {
    $ids=[]; $deleted=array_map('strtolower',$state['deletedCustomExerciseIDs']??[]);
    if(count($state['customExercises']??[])>400) return false;
    foreach($state['customExercises']??[] as $item) {
        $id=strtolower($item['id']);
        if(isset($ids[$id]) || in_array($id,$deleted,true)) return false;
        $ids[$id]=true;
    }
    return true;
}
// 分块同步与整包等价的洞察一致性：本次上传的事件/反馈自身构成合法图，
// 不得与存量对象撞 ID，引用存量父对象时类型与分组必须一致。
// 存量自身的旧问题不阻塞新上传（与分块路径“只校验本次涉及对象”的原则一致）。
function cloudInsightEventsCompatible(array $uploaded, array $stored): bool {
    if(!cloudInsightGraphValid($uploaded,'groupID')) return false;
    $byID=[];
    foreach($stored as $event) if(!isset($byID[$event['id']])) $byID[$event['id']]=$event;
    foreach($uploaded as $event) {
        if(isset($byID[$event['id']])) return false;
        foreach($event['previousIDs'] as $parent) {
            if(!isset($byID[$parent])) continue;
            if($byID[$parent]['kind']!==$event['kind'] || $byID[$parent]['groupID']!==$event['groupID']) return false;
        }
    }
    return true;
}
function cloudInsightFeedbackCompatible(array $uploaded, array $stored): bool {
    if(!cloudInsightGraphValid($uploaded,'scope')) return false;
    $byID=[];
    foreach($stored as $entry) if(!isset($byID[$entry['id']])) $byID[$entry['id']]=$entry;
    foreach($uploaded as $entry) {
        if(isset($byID[$entry['id']])) return false;
        foreach($entry['previousIDs'] as $parent) {
            if(!isset($byID[$parent])) continue;
            if($byID[$parent]['kind']!==$entry['kind'] || $byID[$parent]['scope']!==$entry['scope']) return false;
        }
    }
    return true;
}
function cloudExperienceValid(array $state): bool {
    if(!cloudPlanDraftsValid($state) || !cloudInsightsValid($state) || !cloudPlanChangesValid($state) || !cloudExecutionTargetsValid($state) || !cloudCustomExercisesValid($state) || !cloudScheduleProposalsValid($state)) return false;
    foreach(($state['days']??[]) as $key=>$day) if(!cloudDayExperienceValid((string)$key,$day)) return false;
    return true;
}


/** Preserve new fields for old clients, then enforce canonical report versions and AI meal provenance. */
function cloudNormalizeCycleOwnership(array $state): array {
    if(!isset($state['days']) || !is_array($state['days'])) return $state;
    // 必须引用真实数组；对 ($state['days'] ?? []) 的临时表达式取引用不会写回。
    foreach($state['days'] as $date=>&$day) {
        if(!is_array($day) || !isset($day['planCycle']) || !is_array($day['planCycle'])) continue;
        $cycle=$day['planCycle'];
        if(!isset($cycle['start'],$cycle['plannedDates'])) continue;
        $start=$cycle['start'];
        if(!is_string($start) || !cloudDateValid($start)) { unset($day['planCycle']); continue; }
        $maximum=(new DateTimeImmutable($start))->modify('+6 days')->format('Y-m-d');
        $end=$cycle['endDate']??$maximum;
        if($date<$start || $date>$end || $end<$start || $end>$maximum) { unset($day['planCycle']); continue; }
        $planned=[];
        foreach($cycle['plannedDates'] as $value) if(is_string($value) && $value>=$start && $value<=$end) $planned[$value]=true;
        $cycle['plannedDates']=array_keys($planned);sort($cycle['plannedDates']);
        $day['planCycle']=$cycle;
    }
    unset($day);
    return $state;
}

function cloudReconcileRecords(array $state, array $previous): array {
    $state=cloudNormalizeCycleOwnership($state);
    $state=cloudPreserveV2Meta($state,$previous);
    $state=cloudPreserveHistory($state,$previous);
    $state=cloudPreserveAIRecords($state,$previous);
    $state=cloudPreservePlanExplanations($state,$previous);
    $days=(array)$state['days']; $oldDays=(array)($previous['days']??[]); ksort($oldDays);
    $legacy=($state['recordIntegrityVersion']??null)!==1;
    $oldMeals=[];
    foreach($oldDays as $day) foreach($day['meals']??[] as $meal) $oldMeals[strtolower($meal['id'])]=$meal;
    foreach($days as $date=>&$day) {
        $before=$oldDays[$date]??[];
        if(function_exists('actionMeasurementMigrate')){
          actionMeasurementMigrate($before,(string)$date);actionMeasurementMigrate($day,(string)$date);
          $deleted=array_values(array_unique(array_merge($before['deletedBodyMeasurementIDs']??[],$day['deletedBodyMeasurementIDs']??[])));
          $measurements=[];foreach(array_merge($before['bodyMeasurements']??[],$day['bodyMeasurements']??[]) as $m){if(isset($m['id']))$measurements[strtolower($m['id'])]=$m;}
          $day['bodyMeasurements']=array_values($measurements);$day['deletedBodyMeasurementIDs']=$deleted;actionMeasurementProject($day);
        }
        $owners=[];foreach($before['exercises']??[] as $old) if(isset($old['planID']))$owners[strtolower($old['id'])]=$old['planID'];
        foreach($day['exercises'] as &$exercise) if(!isset($exercise['planID']) && isset($owners[strtolower($exercise['id'])]))$exercise['planID']=$owners[strtolower($exercise['id'])];
        unset($exercise);
        if($legacy) {
            foreach(['weeklyReviewHistory','deletedWeeklyReviewIDs'] as $field) if(isset($before[$field])) $day[$field]=$before[$field];
            foreach($day['meals'] as &$meal) {
                $old=$oldMeals[strtolower($meal['id'])]??[];
                foreach(['placementConflictDates','placementConfirmedAt'] as $field) {
                    if(array_key_exists($field,$old)) $meal[$field]=$old[$field];
                    else unset($meal[$field]);
                }
            }
            unset($meal);
        }
        $deleted=array_unique(array_map('strtolower',array_merge($day['deletedWeeklyReviewIDs']??[],$before['deletedWeeklyReviewIDs']??[])));
        if($deleted) $day['deletedWeeklyReviewIDs']=array_values($deleted);
        $versions=[];
        $records=$day['weeklyReviewHistory']??[];
        if(isset($day['weeklyReview'])) $records[]=$day['weeklyReview'];
        if(!$legacy) $records=array_merge($records,$before['weeklyReviewHistory']??[],isset($before['weeklyReview'])?[$before['weeklyReview']]:[]);
        // An old client cannot silently erase versions it cannot display.
        if($legacy && isset($before['weeklyReview']) && (isset($day['weeklyReview']) || !empty($before['weeklyReviewHistory']))) $records[]=$before['weeklyReview'];
        foreach($records as $review) {
            if(empty($review['result']) || in_array(strtolower($review['id']),$deleted,true)) continue;
            $id=strtolower($review['id']);
            if(isset($versions[$id]) && $versions[$id]['updatedAt']>$review['updatedAt']) continue;
            $review['photos']=[];unset($review['compareWith']);$review['baseline']=(object)($review['baseline']??[]);
            $versions[$id]=$review;
        }
        $ordered=array_values($versions);
        usort($ordered,static fn($a,$b)=>($b['updatedAt']<=>$a['updatedAt']) ?: strcmp(strtoupper($b['id']),strtoupper($a['id'])));
        unset($day['weeklyReview'],$day['weeklyReviewHistory']);
        if($ordered) $day['weeklyReview']=array_shift($ordered);
        if($ordered) $day['weeklyReviewHistory']=$ordered;
    }
    unset($day);
    $groups=[];$prior=[];
    foreach($oldDays as $date=>$day) foreach($day['meals']??[] as $meal) {
        $source=$meal['sourceAIJobID']??'';
        $key=$source.'/'.strtolower($meal['id']);
        if($source!=='' && !isset($prior[$key])) $prior[$key]=['date'=>$date,'meal'=>$meal];
    }
    ksort($days);
    foreach($days as $date=>$day) foreach($day['meals'] as $meal) {
        $source=$meal['sourceAIJobID']??'';
        if($source!=='') $groups[$source.'/'.strtolower($meal['id'])][]=['date'=>$date,'meal'=>$meal];
    }
    foreach($groups as $source=>$items) {
        if(count($items)<2) continue;
        $old=$prior[$source]??null;
        usort($items,static function($a,$b)use($old) {
            $time=($b['meal']['placementConfirmedAt']??-INF)<=>($a['meal']['placementConfirmedAt']??-INF);
            if($time) return $time;
            $preferred=(int)($b['date']===($old['date']??null))<=>(int)($a['date']===($old['date']??null));
            return $preferred ?: strcmp($a['date'],$b['date']) ?: strcmp(strtoupper($a['meal']['id']),strtoupper($b['meal']['id']));
        });
        $winner=$items[0];$meal=$winner['meal'];$concurrent=false;
        foreach(array_slice($items,1) as $item) if(isset($item['meal']['placementConfirmedAt']) && (float)$item['meal']['placementConfirmedAt']!==(float)($old['meal']['placementConfirmedAt']??-INF) && (float)($meal['placementConfirmedAt']??-INF)!==(float)($old['meal']['placementConfirmedAt']??-INF)) $concurrent=true;
        if(!isset($meal['placementConfirmedAt']) || $concurrent) {
            $dates=[];
            foreach($items as $item) $dates=array_merge($dates,[$item['date']],$item['meal']['placementConflictDates']??[]);
            $meal['placementConflictDates']=array_values(array_unique($dates));sort($meal['placementConflictDates']);
        }
        foreach(array_unique(array_column($items,'date')) as $date) $days[$date]['meals']=array_values(array_filter($days[$date]['meals'],static fn($m)=>strtolower($m['id'])!==strtolower($items[0]['meal']['id'])));
        $days[$winner['date']]['meals'][]=$meal;
    }
    foreach($days as $date=>&$entry) { $entry=cloudRestoreCancelledExecution($entry,$oldDays[$date]??[]); $entry=cloudApplyPlanActions($entry); }unset($entry);
    $state['days']=(object)$days;
    return $state;
}

/** A missing local cache is not deletion. Only explicit tombstones remove saved AI results. */
function cloudPreserveAIRecords(array $state, array $previous): array {
    $deleted=array_values(array_unique(array_merge($previous['deletedAIJobIDs']??[],$state['deletedAIJobIDs']??[])));
    $blocked=array_fill_keys(array_map('strtolower',$deleted),true);
    $jobs=[];
    foreach($previous['aiJobs']??[] as $job) {
        if(isset($job['result']) && !isset($blocked[strtolower($job['id'])])) $jobs[strtolower($job['id'])]=$job;
    }
    foreach($state['aiJobs']??[] as $job) {
        $key=strtolower($job['id']);
        if(isset($blocked[$key])) continue;
        // A stale pending task must not erase a previously committed report.
        if(isset($jobs[$key]['result']) && !isset($job['result'])) continue;
        $jobs[$key]=$job;
    }
    $state['aiJobs']=array_values($jobs);
    if($deleted) $state['deletedAIJobIDs']=$deleted;
    return $state;
}


/** Preserve optional rich analysis and immutable start targets omitted by old Codable clients. */
function cloudPreservePlanExplanations(array $state, array $previous): array {
    $days=(array)($state['days']??[]); $oldDays=(array)($previous['days']??[]);
    foreach($days as $date=>&$day) {
        $cycle=$day['planCycle']??null; $old=$oldDays[$date]['planCycle']??null;
        // Pre-v75 Codable clients omit endDate. Do not silently expand a
        // truncated interval again when the same marker is round-tripped.
        if(is_array($cycle) && is_array($old) && !isset($cycle['endDate']) && isset($old['endDate'])
           && ($cycle['start']??null)===($old['start']??null)) {
            $day['planCycle']['endDate']=$old['endDate']; $cycle=$day['planCycle'];
        }
        $oldSessions=[];foreach($oldDays[$date]['workoutSessions']??[] as $session)$oldSessions[strtolower($session['id'])]=$session;
        foreach($day['workoutSessions']??[] as $index=>$session) {
            $prior=$oldSessions[strtolower($session['id'])]??null;
            if(isset($prior['executionBaseline']))$day['workoutSessions'][$index]['executionBaseline']=$prior['executionBaseline'];
            if(!array_key_exists('pauseIntervals',$session)&&isset($prior['pauseIntervals']))$day['workoutSessions'][$index]['pauseIntervals']=$prior['pauseIntervals'];
        }
        if(is_array($cycle) && is_array($old) && ($cycle['explanationVersion']??null)!==1
           && ($cycle['start']??null)===($old['start']??null) && ($cycle['endDate']??null)===($old['endDate']??null) && ($cycle['plannedDates']??[])===($old['plannedDates']??[])) {
            foreach(['sourceJobID','explanationVersion'] as $key) if(isset($old[$key])) $day['planCycle'][$key]=$old[$key];
        }
    }
    unset($day);
    $state['days']=(object)$days;
    $oldJobs=[];
    foreach($previous['aiJobs']??[] as $job) $oldJobs[$job['id']]=$job;
    foreach($state['aiJobs']??[] as $index=>$job) {
        $before=$oldJobs[$job['id']]??null;
        if(($job['result']['kind']??null)==='coach' && !isset($job['result']['coach']) && isset($before['result']['coach'])) {
            $state['aiJobs'][$index]['result']['coach']=$before['result']['coach'];
        }
        if(($job['result']['kind']??null)==='report' && isset($before['result']['training_feedback'])) {
            $same=true;foreach(['summary','training','nutrition','recovery','notes'] as $field)if(($job['result'][$field]??null)!=($before['result'][$field]??null))$same=false;
            if($same)$state['aiJobs'][$index]['result']['training_feedback']=$before['result']['training_feedback'];
        }
        if(($job['result']['kind']??null)==='plan' && !isset($job['result']['explanation'])
           && isset($before['result']['explanation'])
           && ($job['result']['sessions']??null)==($before['result']['sessions']??null)) {
            $state['aiJobs'][$index]['result']['explanation']=$before['result']['explanation'];
        }
    }
    return $state;
}


/** History is append-only. A legacy client cannot delete observations it cannot decode. */
/**
 * 0.15.0 新增：行动状态、计划草稿/模板（含删除标记）、目标体重。
 * 旧客户端（无 syncSchemaVersion 标记）解码即丢这些字段——按 ID 并集前向保留；
 * 新客户端（标记 >= 2）的上传视为权威（删除走软删除标记，不会静默清空）。
 */
function cloudPreserveV2Meta(array $state, array $previous): array {
    foreach(['planDrafts','planTemplates'] as $field) {
        $known=[];foreach($previous[$field]??[] as $record)$known[strtolower($record['id'])]=$record;
        foreach($state[$field]??[] as $index=>$record) {
            $old=$known[strtolower($record['id'])]??[];
            if($field==='planDrafts' && !array_key_exists('singleDay',$record) && isset($old['singleDay']))$state[$field][$index]['singleDay']=$old['singleDay'];
            if($field==='planTemplates' && !array_key_exists('recurrence130',$record) && isset($old['recurrence130']))$state[$field][$index]['recurrence130']=$old['recurrence130'];
            if($field==='planTemplates' && !array_key_exists('singleDay',$record['draft']??[]) && isset($old['draft']['singleDay']))$state[$field][$index]['draft']['singleDay']=$old['draft']['singleDay'];
        }
    }

    if(($state['syncSchemaVersion']??0)>=2) return $state;
    foreach(['actionStates','planDrafts','planTemplates'] as $field) {
        $records=[];
        foreach(array_merge($previous[$field]??[],$state[$field]??[]) as $record) {
            $id=strtolower((string)($record['id']??''));
            if($id==='')continue;
            if(!isset($records[$id])) $records[$id]=$record;
            elseif((float)($record['updatedAt']??-INF)>=(float)($records[$id]['updatedAt']??-INF)) $records[$id]=$record;
        }
        if($records) { ksort($records);$state[$field]=array_values($records); }
    }
    foreach(['deletedPlanDraftIDs','deletedPlanTemplateIDs'] as $field) {
        $union=array_values(array_unique(array_merge($state[$field]??[],$previous[$field]??[])));
        if($union) { sort($union);$state[$field]=$union; }
    }
    if(isset($previous['profile']['targetWeightKg']) && !array_key_exists('targetWeightKg',$state['profile']??[])) {
        $state['profile']['targetWeightKg']=$previous['profile']['targetWeightKg'];
    }
    return $state;
}

function cloudPreserveHistory(array $state, array $previous): array {
    $days=(array)($state['days']??[]);
    $oldDays=(array)($previous['days']??[]);
    $fields=['planActions','goalVersions','planVersions','insightEvents','insightFeedback','planShifts','phaseReports'];
    foreach(array_unique(array_merge(array_keys($oldDays),array_keys($days))) as $date) {
        $old=$oldDays[$date]??[];
        $has=false;foreach($fields as $field)if(!empty($old[$field]) || !empty($days[$date][$field])){$has=true;break;}
        if(!$has)continue;
        $day=$days[$date]??['exercises'=>[],'meals'=>[]];
        foreach($fields as $field) {
            $records=[];
            // Once committed, a snapshot is immutable even if an incoming ID repeats.
            foreach(array_merge($old[$field]??[],$day[$field]??[]) as $record) {
                $id=strtolower((string)($record['id']??''));
                if($id!=='' && !isset($records[$id])) $records[$id]=$record;
                elseif($id!=='' && $field==='planShifts') {
                    foreach($record as $key=>$value) if(!array_key_exists($key,$records[$id])) $records[$id][$key]=$value;
                }
            }
            if($records) { ksort($records);$day[$field]=array_values($records); }
        }
        $days[$date]=$day;
    }
    $state['days']=(object)$days;
    return $state;
}


/** Check causal references without recursion; timestamps are not conflict winners. */
function cloudInsightGraphValid(array $records,string $field): bool {
    $byID=[];$degree=[];$children=[];
    foreach($records as $record) {
        $id=$record['id'];
        if(isset($byID[$id]) || in_array($id,$record['previousIDs'],true) || count(array_unique($record['previousIDs']))!==count($record['previousIDs']))return false;
        $byID[$id]=$record;$degree[$id]=0;
    }
    foreach($records as $record)foreach($record['previousIDs'] as $parent) {
        if(!isset($byID[$parent]))continue;
        if($byID[$parent]['kind']!==$record['kind'] || $byID[$parent][$field]!==$record[$field])return false;
        $degree[$record['id']]++;$children[$parent][]=$record['id'];
    }
    $queue=[];foreach($degree as $id=>$n)if($n===0)$queue[]=$id;
    for($i=0;$i<count($queue);$i++)foreach($children[$queue[$i]]??[] as $child)if(--$degree[$child]===0)$queue[]=$child;
    return count($queue)===count($byID);
}

function cloudInsightsValid(array $state): bool {
    $events=[];$feedback=[];
    foreach((array)($state['days']??[]) as $date=>$day) {
        foreach($day['insightEvents']??[] as $event) {
            $expected=$date.'/'.$event['kind'];
            if($event['kind']==='workout') {
                if(!isset($event['sourceSessionID']))return false;
                $expected.='/'.strtolower($event['sourceSessionID']);
            } elseif(isset($event['sourceSessionID']))return false;
            if($event['date']!==$date || $event['groupID']!==$expected)return false;
            if(isset($event['action'])) {
                $action=$event['action'];
                if($action['date']!==$date)return false;
                if($action['type']==='workout_summary' && ($event['kind']!=='workout' || strtolower($action['sessionID']??'')!==strtolower($event['sourceSessionID'])))return false;
                // 计划跟进的受控动作是日程调整（schedule_shift）；其余动作类型与事件类型一致。
                if($action['type']!=='workout_summary' && (isset($action['sessionID']) || ($action['type']!==$event['kind'] && !($event['kind']==='plan' && $action['type']==='schedule_shift'))))return false;
            }
            if($event['state']==='expired' && !$event['isTodayReminder'])return false;
            $events[]=$event;
        }
        foreach($day['insightFeedback']??[] as $entry) {
            if($entry['date']!==$date)return false;
            $scope=match($entry['action']) {
                'helpful'=>isset($entry['eventID'])?$entry['kind'].'/helpful/'.$entry['eventID']:null,
                'read','unread'=>isset($entry['eventID'])?$entry['kind'].'/reading/'.$entry['eventID']:null,
                'archive','unarchive'=>isset($entry['eventID'])?$entry['kind'].'/archive/'.$entry['eventID']:null,
                'reduce','normal'=>$entry['kind'].'/preference',
                'dismiss_today','restore_today'=>$entry['kind'].'/today/'.$date,
                default=>null,
            };
            if($scope===null || $entry['scope']!==$scope)return false;
            $feedback[]=$entry;
        }
    }
    return cloudInsightGraphValid($events,'groupID') && cloudInsightGraphValid($feedback,'scope');
}

/** Optional adoption audit trail: actual before/after, never invented for older plans. */
function cloudPlanChangesValid(array $state): bool {
    foreach($state['days']??[] as $day) foreach($day['planVersions']??[] as $plan) {
        if(!isset($plan['changes'])) continue;
        $seen=[];
        foreach($plan['changes'] as $change) {
            $date=$change['date'];
            if(isset($seen[$date]) || !in_array($date,$plan['scopeDates'],true)) return false;
            $seen[$date]=true;
            $retained=in_array($date,$plan['retainedDates'],true);
            if($change['retained']!==$retained || ($retained && $change['before']!=$change['after'])) return false;
            foreach(['before','after'] as $side) {
                if(count($change[$side])>30) return false;
                foreach($change[$side] as $exercise) {
                    if(count($exercise['sets'])>50) return false;
                    if(isset($exercise['custom_id'])!==isset($exercise['custom_unit'])) return false;
                    if(isset($exercise['custom_id']) && (isset($exercise['library_id']) || isset($exercise['library_query']))) return false;
                    foreach($exercise['sets'] as $set) {
                        if(($set['weight']??0)<0 || ($set['weight']??0)>2000 || $set['reps']<0 || $set['reps']>1000) return false;
                    }
                }
            }
        }
        $scope=array_unique($plan['scopeDates']);
        if(count($scope)!==count($seen)) return false;
    }
    return true;
}

/** Preserve legacy absent targets, validate only values actually captured. */
function cloudExecutionTargetsValid(array $state): bool {
    foreach($state['days']??[] as $day) foreach($day['workoutSessions']??[] as $session) {
        $baseline=$session['executionBaseline']??null;if($baseline===null)continue;
        if(isset($baseline['restSeconds']) && ($baseline['restSeconds']<0 || $baseline['restSeconds']>3600))return false;
        foreach($baseline['sets'] as $set) {
            if($set['unit']==='time' && (isset($set['targetReps']) || isset($set['targetWeight'])))return false;
            if(isset($set['targetReps']) && ($set['targetReps']<1 || $set['targetReps']>1000))return false;
            if(isset($set['targetWeight']) && ($set['targetWeight']<0 || $set['targetWeight']>2000))return false;
        }
    }
    return true;
}

/** An explicit cancellation never destroys a concurrent real workout. */
function cloudApplyPlanActions(array $day): array {
    if(isset($day['workoutStartedAt']) || isset($day['workoutSavedAt'])) return $day;
    foreach($day['workoutSessions']??[] as $session) if(isset($session['startedAt']) || isset($session['savedAt']))return $day;
    foreach($day['exercises']??[] as $exercise) foreach($exercise['sets']??[] as $set) if(($set['completed']??false)===true)return $day;
    $removed=[];$clear=false;
    foreach($day['planActions']??[] as $action) if(($action['kind']??'')==='ended') {
        foreach($action['exerciseIDs']??[] as $id)$removed[strtolower($id)]=true;
        $owner=$day['planCycle']['sourceJobID']??('legacy-plan-'.($day['planCycle']['start']??''));
        $clear=$clear || (($action['clearsCycle']??false) && $owner===$action['planID']);
    }
    $day['exercises']=array_values(array_filter($day['exercises']??[],fn($item)=>!isset($removed[strtolower($item['id'])])));
    if($clear && !$day['exercises'])unset($day['planCycle']);
    return $day;
}

function cloudRestoreCancelledExecution(array $day,array $before): array {
    $started=isset($before['workoutStartedAt']) || isset($before['workoutSavedAt']);
    foreach($before['workoutSessions']??[] as $session)$started=$started || isset($session['startedAt']) || isset($session['savedAt']);
    foreach($before['exercises']??[] as $exercise)foreach($exercise['sets']??[] as $set)$started=$started || ($set['completed']??false);
    if(!$started)return $day;
    $cancelled=[];foreach($day['planActions']??[] as $action)if(($action['kind']??'')==='ended')foreach($action['exerciseIDs']??[] as $id)$cancelled[strtolower($id)]=true;
    if(!$cancelled)return $day;
    $present=[];foreach($day['exercises']??[] as $exercise)$present[strtolower($exercise['id'])]=true;
    foreach($before['exercises']??[] as $exercise)if(isset($cancelled[strtolower($exercise['id'])]) && !isset($present[strtolower($exercise['id'])]))$day['exercises'][]=$exercise;
    foreach(['workoutStartedAt','workoutSavedAt','workoutEndedAt','workoutSessions','activeWorkoutSessionID'] as $field)if(!isset($day[$field]) && isset($before[$field]))$day[$field]=$before[$field];
    return $day;
}
