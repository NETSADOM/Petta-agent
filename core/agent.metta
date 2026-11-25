; agent.metta — the P-agent loop, written in MeTTa.
;
;   !(run-agent "your goal")  →  (done "answer")
;                               | (done-unverified "answer")   final accepted with open tasks
;                               | (stopped REASON)
;
; Gemini proposes; THIS file decides. Every proposal is validated (llm.metta),
; permission-checked, executed, and recorded as a (step ...) in &wm.

!(import! &self store)
!(import! &self schema)
!(import! &self llm)
!(import! &self "io_helper.py")
!(import! &self tools)
!(import! &self skills)
!(import! &self verify)

; ---------------- the agent's own tools: talking to the user ----------------
; Core, not capabilities: every agent can message and ask its user.
; MeTTa tools (no worker thread), so a pending question can never be abandoned
; by a timeout and then steal your next line. io_helper never raises.
!(declare-tool send-message "show the user a message now (progress, a partial result, a warning) without waiting for a reply; input is the message text" safe metta)
!(set-tool-option send-message retry no)
!(set-tool-option send-message max-length 4000)
!(declare-tool ask-user "ask the user a question and wait for the answer; only when you cannot continue without them. Input is the question." safe metta)
!(set-tool-option ask-user retry no)
!(set-tool-option ask-user max-length 1000)
!(set-tool-option ask-user max-calls 5)

(= (metta-tool send-message $text) (py-call (io_helper.send_message $text)))
(= (metta-tool ask-user $question) (py-call (io_helper.ask_user $question)))

!(set-config max-replans 2)
; max-iterations (turns per goal, default 40) is set in context.metta: the prompt shows it
!(set-config max-invalid 3)          ; bad replies IN A ROW before giving up
!(set-config max-llm-errors 3)       ; temporary API errors IN A ROW before giving up
!(set-config max-refusals 3)         ; repeated failing calls refused, then stop
!(set-config max-failures-in-row 8)  ; this many failed steps in a row (any tools) = stuck
!(set-config agent-depth 0)          ; 0 = the main agent, 1 = a helper (sub-agent)
!(set-config sub-agent-turns 20)     ; turn limit of one helper run
!(set-config max-final-rejections 2) ; then accept final as done-unverified

(= (show $x) (emit $x))      ; all output goes through emit (schema.metta)

(= (task-list) (collapse (match &wm (task $i $d $s) ($i $d $s))))

; ---------------- working memory reset ----------------
(= (clear-wm) (collapse (let $a (get-atoms &wm) (remove-atom &wm $a))))

(= (count-errors $tool)
   (size-atom (collapse (match &wm (step $n $tool $in (error $e)) $n))))

; errors of $tool in the LATEST steps, with nothing else in between. Long runs
; use this: three bad replies spread over 40 turns are noise, three in a row
; mean the model is stuck.
(= (trailing-errors $tool) (trailing-from $tool (step-count)))
(= (trailing-from $tool $n)
   (if (< $n 1)
       0
       (let $s (collapse (match &wm (step $n $t $i $o) ($t $o)))
            (if (== $s ())
                0
                (let $x (car-atom $s)
                     (if (and (== (index-atom $x 0) $tool) (== (car-atom (index-atom $x 1)) error))
                         (+ 1 (trailing-from $tool (- $n 1)))
                         0))))))


; failed steps at the end of the history, whatever the tool
(= (trailing-failures) (failures-from (step-count)))
(= (failures-from $n)
   (if (< $n 1)
       0
       (let $o (collapse (match &wm (step $n $t $i $out) $out))
            (if (and (not (== $o ())) (== (car-atom (car-atom $o)) error))
                (+ 1 (failures-from (- $n 1)))
                0))))

; the latest failed steps, newest first: ((N TOOL ERROR) ...)
(= (last-errors $k)
   (map-atom (take (sort-atom (collapse (match &wm (step $n $t $i (error $e))
                                               ((- 0 $n) $n $t (clip-to $e 150)))))
                   $k)
             $x (cdr-atom $x)))

; what the user is told when a run stops without an answer (ui.py renders it)
(= (stuck-report $result)
   (stop-report (goal (goal-text)) (reason (index-atom $result 1))
                (progress-report) (recent-errors (last-errors 3))))

; where the plan stands — told to the user when the turn limit ends a run
(= (progress-report)
   (let* (($all (task-list))
          ($done (collapse (match &wm (task $id $d completed) $id))))
         (progress (turns (current-turn)) (steps (step-count))
                   (tasks-done (size-atom $done) of (size-atom $all))
                   (open (open-tasks)))))

; Tool execution — (execute TOOL INPUT) with all its gates — lives in tools.metta.

; ---------------- the loop ----------------
(= (run-agent $goal)
   (let* (($c (clear-wm))
          ($g (set-goal $goal))
          ($plan (make-plan))
          ($s (show (plan-result $plan)))
          ($s2 (if (== (task-list) ()) () (show (plan (task-list)))))
          ($s3 (if (fatal $plan) () (show (cancel-hint))))
          ($result (if (fatal $plan) (stopped $plan) (agent-loop 1)))
          ($rep (if (== (car-atom $result) stopped) (show (stuck-report $result)) ()))
          ($ses (if (== (config-value agent-depth) 0)                     ; helpers are not session tasks
                    (py-call (session.record (goal-text) (repr $result))) ()))
          ($m (form-episode $result))        ; memory: keep successful runs
          ($f (if (== (car-atom $result) done) (learn-recoveries) ())))   ; what fixed failures
         $result))

; a permanent API error (bad key, unknown model, ...) stops everything at once
(= (fatal $r)
   (if (== (car-atom $r) error)
       (not (temporary-error (index-atom $r 1)))
       False))

(= (agent-loop $i)
   (if (> $i (config-value max-iterations))
       (stopped (iteration-limit (progress-report)))
       (if (>= (trailing-failures) (config-value max-failures-in-row))
           (stopped (no-progress (failed-in-a-row (trailing-failures))))
           (if (py-call (ui.cancel_requested))       ; you typed c + Enter (never blocks)
               (cancel-run)
               (let $t (set-turn $i)
                    (handle (propose-next) $i))))))

; cancel: unfinished tasks → cancelled, logged; no episode is formed
(= (cancel-run)
   (let* (($open (collapse (match &wm (task $id $d $s)
                                  (if (or (== $s completed) (or (== $s failed) (== $s cancelled)))
                                      (empty) $id))))
          ($c (collapse (let $id (superpose $open) (set-status $id cancelled))))
          ($l (py-call (toolrunner.audit cancelled agent (goal-text) cancelled (repr $open)))))
         (cancelled)))

(= (handle $p $i)
   (case (car-atom $p)
         ((action    (do-action $p $i))
          (actions   (do-actions $p $i))
          (task-done (do-task-done $p $i))
          (task-failed (do-task-failed $p $i))
          (replan    (do-replan $p $i))
          (missing-capability (do-missing $p $i))
          (learn     (do-learn $p $i))
          (ask-user  (do-ask $p $i))
          (final     (do-final $p $i))
          (invalid   (do-invalid $p $i))
          (error     (do-llm-error $p $i)))))

(= (continue $i) (agent-loop (+ $i 1)))

; One turn = one reply. It may hold one call (action ..) or several (actions ..).
; Each call goes through (execute ..) with all its gates; every result is
; recorded as a (step ..) and is in the context of the NEXT turn.
(= (do-action $p $i)
   (let $r (run-call (index-atom $p 1) (index-atom $p 2) $i)
        (after-calls $r $i)))

(= (do-actions $p $i) (after-calls (run-calls (cdr-atom $p) $i) $i))

; → ran | (stop REASON); a batch stops at the first (stop ..)
(= (run-calls $calls $i)
   (if (== $calls ())
       ran
       (let* (($c (car-atom $calls))
              ($r (run-call (index-atom $c 1) (index-atom $c 2) $i)))
             (if (== $r ran) (run-calls (cdr-atom $calls) $i) $r))))

(= (after-calls $r $i)
   (if (== $r ran) (continue $i) (stopped (index-atom $r 1))))

; A call that already failed twice in exactly this form is NOT run again: the
; model is told to change the input or the tool (recovery by doing something
; different). Only when it keeps insisting (max-refusals) does the run stop.
(= (refusals) (size-atom (collapse (match &wm (step $n $t $in (error (repeated-call $k $m))) $n))))

(= (run-call $tool $input $i)
   (if (stuck $tool $input)
       (let* (($out (error (repeated-call (count-errors-of $tool $input)
                                          "this exact call already failed; do not repeat it: change the input, use another tool, ask-user, or mark the task failed")))
              ($s1 (show (step $i (current-task) $tool $input)))
              ($s2 (show (result $out)))
              ($r (record-step $tool $input $out)))
             (if (>= (refusals) (config-value max-refusals))
                 (stop (repeated-failure $tool $input))   ; not (stuck ..): that would evaluate!
                 ran))
       (let* (($task (start-current-task))          ; pending → running
              ($s1 (show (step $i $task $tool $input)))
              ($out (flag-repeat (execute-call $tool $input)))
              ($s2 (show (result $out)))
              ($r (record-step $tool $input $out)))
             ran)))

; Models often call a SKILL as if it were a tool, e.g. (action summarization "x").
; Instead of a bare unknown-tool error (and a wasted turn), the skill is loaded
; and the model is told what happened.
(= (execute-call $tool $input)
   (if (and (not (tool-known $tool)) (skill-known $tool))
       (let $r (execute read-skill (repr $tool))
            (if (== (car-atom $r) ok)
                (ok (skill-not-tool $tool "is a SKILL, not a tool: its guide is now loaded (that is what read-skill does). Do the work with tools from the catalog, following the guide."
                                    (index-atom $r 1)))
                $r))
       (execute $tool $input)))

; Loop guard for SUCCESSFUL calls: a result identical to an earlier step's
; (the same page re-read, a "cleaned" copy that is still the same junk) means
; the approach is not making progress. The result is kept, but the model is
; told so in front of it — the clipped step history still shows the warning.
; Short results ("exit code 0 (no output)") repeat legitimately and are skipped.
(= (flag-repeat $out)
   (if (and (is-expression $out) (== (car-atom $out) ok))
       (let $prev (collapse (match &wm (step $n $t $i $out) $n))
            (if (or (== $prev ()) (< (py-call (toolrunner.length (index-atom $out 1))) 200))
                $out
                (ok (repeated-result (same-as-steps $prev)
                                     "SAME result as before: this approach is not making progress. Use another source or tool, or finish with what you have."
                                     (index-atom $out 1)))))
       $out))

; real failures of this exact call (refusals not counted)
(= (count-errors-of $tool $input)
   (size-atom (collapse (match &wm (step $n $tool $input (error $e))
                               (if (and (is-expression $e) (== (car-atom $e) repeated-call)) (empty) $n)))))

(= (task-exists $id) (not (== (collapse (status-of $id)) ())))

; (task-done t1) or (task-done t1 t2 t3): several tasks in ONE reply (one LLM call)
(= (mark-done $id)
   (let* (($out (if (task-exists $id)
                    (let $r (set-status $id completed) (ok completed))
                    (error unknown-task)))
          ($s (show (task-done $id $out)))
          ($r2 (record-step task-done $id $out)))
         $out))

(= (do-task-done $p $i)
   (let* (($ids (cdr-atom $p))                  ; bind first: superpose does not evaluate
          ($rs (collapse (let $id (superpose $ids) (mark-done $id)))))
         (continue $i)))

; A final answer closes the task being worked on: its tools ran (status
; running) and the model now says the goal is reached. Sending (task-done ..)
; first cost an extra LLM call every goal, and models often skip it. Tasks that
; were never started stay open, so skipped work is still caught by verification.
; The closing is PROVISIONAL: verification runs with these tasks completed;
; accepted → recorded as steps, refused → back to running (work goes on).
(= (close-running-tasks)
   (let $ids (running-tasks)
        (collapse (let $id (superpose $ids) (let $r (set-status $id completed) $id)))))

(= (reopen-tasks $ids)
   (collapse (let $id (superpose $ids) (set-status $id running))))

(= (record-closed $ids)
   (collapse (let $id (superpose $ids)
                  (let* (($out (ok completed-with-final))
                         ($s (show (task-done $id $out)))
                         ($r (record-step task-done $id $out)))
                        $id))))

; the task failed: dependents (and their dependents) become blocked
(= (do-task-failed $p $i)
   (let* (($id (index-atom $p 1))
          ($out (if (task-exists $id)
                    (ok (blocked (fail-task $id)))
                    (error unknown-task)))
          ($s (show (task-failed $id $out)))
          ($r (record-step task-failed $id $out)))
         (continue $i)))

; new plan from what was learned; limited so Gemini can't replan forever
(= (do-replan $p $i)
   (if (>= (size-atom (collapse (match &wm (step $n replan $w $o) $n))) (config-value max-replans))
       (let $r (record-step replan (index-atom $p 1) (error replan-limit)) (continue $i))
       (let* (($plan (make-plan))
              ($s (show (replanned $plan)))
              ($s2 (if (== (task-list) ()) () (show (plan (task-list)))))
              ($r (record-step replan (index-atom $p 1)
                               (if (== (car-atom $plan) planned) (ok $plan) (error $plan)))))
             (if (fatal $plan) (stopped $plan) (continue $i)))))

; no tool can do it: remember the gap in &kb (saved) for the developer to review
(= (do-missing $p $i)
   (let* (($what (index-atom $p 1))
          ($k (remember (capability-gap $what) gemini 0.5))
          ($s (show (missing-capability $what)))
          ($r (record-step missing-capability $what (ok recorded))))
         (continue $i)))

; Gemini wants to remember a fact: PeTTa's memory gates decide (memory.metta)
(= (do-learn $p $i)
   (let* (($c (index-atom $p 1))
          ($out (learn-fact $c (index-atom $p 2) gemini))
          ($s (show (learn $c $out)))
          ($r (record-step learn $c $out)))
         (continue $i)))

; (ask-user "q") is the same as (action ask-user "q"): one tool, same gates
(= (do-ask $p $i)
   (let* (($q (index-atom $p 1))
          ($out (execute ask-user $q))
          ($s (if (== (car-atom $out) error) (show (result $out)) ()))
          ($r (record-step ask-user $q $out)))
         (continue $i)))

; PeTTa, not Gemini, decides whether the work is finished: verify.metta runs
; symbolic → objective → semantic checks. Rejected answers go back to Gemini
; with the reasons; after max-final-rejections → done-unverified (never silent).
(= (do-final $p $i)
   (let* (($answer (index-atom $p 1))
          ($closed (close-running-tasks))
          ($problems (verify-answer $answer)))
         (if (== $problems ())
             (let $c (record-closed $closed) (done $answer))
             (if (>= (count-errors finish) (config-value max-final-rejections))
                 (let $c (record-closed $closed) (done-unverified $answer))
                 (let* (($o (reopen-tasks $closed))
                        ($s (show (final-rejected $problems)))
                        ($r (record-step finish $answer (error (verification-failed $problems)))))
                       (continue $i))))))

; bad reply: tell Gemini (it sees the step next time), give up after a few
(= (do-invalid $p $i)
   (let* (($s (show (gemini-reply $p)))
          ($r (record-step gemini reply (error $p))))
         (if (>= (trailing-errors gemini) (config-value max-invalid))
             (stopped too-many-invalid-replies)
             (continue $i))))

(= (do-llm-error $p $i)
   (if (fatal $p)
       (stopped $p)
       (let* (($s (show (gemini-error $p)))
              ($r (record-step gemini-api call (error $p)))
              ($k (trailing-errors gemini-api)))
             (if (>= $k (config-value max-llm-errors))
                 (stopped $p)
                 (let $b (py-call (recovery.sleep (* $k (config-value llm-backoff))))   ; back off
                      (continue $i))))))

; ================================================================ sub-agents
; (action delegate "complete sub-task") — a HELPER agent does a self-contained
; part of the work with a fresh, small context (its own plan, steps, turn
; limit) and returns its answer as the tool result. The parent's working
; memory is saved before and restored after, so the parent carries on exactly
; where it was; only the helper's answer enters the parent's context. That
; keeps long goals short in the prompt. Helpers cannot start helpers (depth 1),
; they use the same tools, gates and approvals.
!(declare-tool delegate "hand a self-contained sub-task to a helper agent that starts with a fresh context and returns its answer. Input: the COMPLETE sub-task with every detail it needs (file names, values, expected output) - the helper sees nothing else. Use it for big independent parts of a long goal." safe metta)
!(set-tool-option delegate retry no)
!(set-tool-option delegate max-length 3000)
!(set-tool-option delegate max-calls 6)

(= (restore-wm $atoms)
   (let* (($c (clear-wm))
          ($added (collapse (let $a (superpose $atoms) (add-atom &wm $a)))))
         restored))

; the helper's result → text for the parent
(= (helper-outcome $r)
   (case (car-atom $r)
         ((done (ok (index-atom $r 1)))
          (done-unverified (ok (helper-answer-unverified (index-atom $r 1))))
          (cancelled (error "the helper was cancelled by the user"))
          ($other (error (helper-stopped (index-atom $r 1)))))))

(= (run-helper $subgoal)
   (let* (($saved (collapse (get-atoms &wm)))
          ($turns (config-value max-iterations))
          ($d (set-config agent-depth 1))
          ($t (set-config max-iterations (config-value sub-agent-turns)))
          ($s1 (show (sub-agent-start $subgoal)))
          ($r (run-agent $subgoal))
          ($s2 (show (sub-agent-end (car-atom $r))))
          ($back (restore-wm $saved))
          ($d2 (set-config agent-depth 0))
          ($t2 (set-config max-iterations $turns)))
         (helper-outcome $r)))

(= (metta-tool delegate $subgoal)
   (if (== (config-value agent-depth) 0)
       (run-helper $subgoal)
       (error "a helper cannot start another helper: do this step yourself")))

; ================================================================ skills on demand
; (action read-skill "NAME")       attach skill NAME to the current task: from
;                                  now on its FULL guide is in every act prompt
;                                  (and its verifiers check the final answer)
; (action read-skill "NAME/FILE")  one extra file of a folder skill (skills.metta)
; The planner's keyword matches are only a start: the model can pull in any
; available skill when it sees it needs one.
!(declare-tool read-skill "load a skill's full guide into the current task (input: the skill name, e.g. research), or read one extra file of a skill (input: NAME/FILE, e.g. code-review/checklist.md)" safe metta)
!(set-tool-option read-skill max-length 200)
!(set-tool-option read-skill max-output 13000)
!(set-tool-option read-skill retry no)

(= (attach-skill $s)
   (let $t (current-task)
        (if (== $t none)
            (let $v (skill-view $s)
                 (ok (py-call (skill_files.render ($v) (config-value skill-guide-chars)))))
            (let* (($r (if (== (collapse (match &wm (task-skill $t $s) yes)) ())
                           (add-atom &wm (task-skill $t $s))
                           ()))
                   ($files (skill-files $s)))
                  (ok (skill-loaded $s (for-task $t) "its full guide is now shown under CURRENT TASK"
                                    (files $files)))))))

(= (read-skill-file $s $rel)
   (let $dir (skill-folder $s)
        (if (== $dir none)
            (error (no-extra-files $s "this skill is written in MeTTa: its whole guide is read-skill NAME"))
            (py-call (skill_files.read_resource $dir $rel)))))

(= (metta-tool read-skill $in)
   (let $spec (py-call (skill_files.split_spec $in))
        (if (== (car-atom $spec) error)
            (error (index-atom $spec 1))
            (let $s (index-atom $spec 1)
                 (if (not (skill-known $s))
                     (let $names (map-atom (skill-catalog) $c (car-atom $c))
                          (error (unknown-skill $s (available $names))))
                     (if (not (skill-available $s))
                         (let $miss (missing-tools $s)
                              (error (skill-unavailable $s (missing-tools $miss))))
                         (if (== (car-atom $spec) skill)
                             (attach-skill $s)
                             (read-skill-file $s (index-atom $spec 2)))))))))
