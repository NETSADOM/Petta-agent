; memory.metta — what P-agent keeps in long-term memory (&kb), and what it recalls.
; Needs core/schema.metta (remember / forget / recall).
;
;   (learn-fact CONTENT CONF SOURCE)  gated remember → (ok remembered) | (error (rejected WHY))
;   (form-episode RESULT)             after a run: keep successful runs as episodes
;   (relevant-facts GOAL)             top facts for this goal: ((CONTENT CONF) ...)
;   (similar-episodes GOAL)           past runs with similar goals
;   (prune-memory)                    keep &kb under memory-max facts

!(import! &self "text.py")
!(import! &self "toolrunner.py")

!(set-config memory-min-confidence 0.6)
!(set-config memory-max-chars 300)
!(set-config memory-top-k 8)
!(set-config memory-max 500)

; Python text arrives as a Symbol; a Symbol with spaces breaks when saved
; ("shout hi" reloads as two symbols). repr turns it into a real String.
(= (as-string $x) (if (== (get-metatype $x) Symbol) (repr $x) $x))

; ---------------- selective formation ----------------
; → () if the fact may be stored, else (WHY)
(= (learn-problems $c $conf)
   (collapse
     (superpose
       ((if (is-expression $c) (empty) not-structured)
        (if (py-call (text.is_probability $conf))
            (if (>= $conf (config-value memory-min-confidence)) (empty) low-confidence)
            bad-confidence)
        (if (> (py-call (toolrunner.length (repr $c))) (config-value memory-max-chars)) too-long (empty))
        (let $why (py-call (text.sensitive_reason (repr $c)))
             (if (py-call (text.is_sensitive (repr $c))) (sensitive $why) (empty)))))))

(= (learn-fact $c $conf $source)
   (let $problems (learn-problems $c $conf)
        (if (== $problems ())
            (let* (($r (remember $c $source $conf))
                   ($p (prune-memory)))
                  (ok remembered))
            (error (rejected $problems)))))

; ---------------- episodes (automatic, after each run) ----------------
; tools that actually succeeded in this run, in order, once each
(= (tools-used)
   (unique-atom (collapse (let $t (match &wm (step $n $t $i (ok $x)) $t)
                               (if (work-tool $t) $t (empty))))))   ; schema.metta

(= (episode-confidence $result)
   (case (car-atom $result)
         ((done 0.8)
          (done-unverified 0)        ; not verified = not a success: never kept
          ($other 0))))

; Only successful runs are kept; the same goal replaces its old episode.
; Like EVERY write to &kb it goes through the gates of learn-fact: sensitivity
; (a goal or answer with a password or an email is not kept), size, pruning.
; Goal and answer are shortened first so an ordinary episode fits the size limit.
(= (form-episode $result)
   (let $conf (episode-confidence $result)
        (if (== $conf 0)
            not-kept
            (let* (($goal (as-string (py-call (text.shorten (py-call (text.normalize (goal-text))) 110))))
                   ($answer (as-string (py-call (text.shorten (index-atom $result 1) 110))))
                   ($tools (cons-atom tools (tools-used)))
                   ($c (episode $goal $tools $answer)))
                  (if (== (learn-problems $c $conf) ())
                      (let* (($old (collapse (forget (episode $goal $t $a))))
                             ($r (learn-fact $c $conf agent)))
                            (kept $goal))
                      (not-kept (learn-problems $c $conf)))))))

; ---------------- recall: only what's relevant ----------------
; score = words shared with the goal; preferences always count
(= (fact-relevance $c $goal)
   (if (== (car-atom $c) preference)
       100
       (py-call (text.overlap (repr $c) $goal))))

(= (take $list $k)
   (if (or (== $k 0) (== $list ()))
       ()
       (let* (($h (car-atom $list)) ($t (cdr-atom $list)) ($k2 (- $k 1)))
             (cons-atom $h (take $t $k2)))))

; ((CONTENT CONF) ...) best first: by relevance, then confidence. Episodes excluded.
(= (relevant-facts $goal)
   (let $scored (collapse (let* (($f (match &kb (fact $c (meta $s $t $conf)) ($c $conf)))
                                 ($c (index-atom $f 0))
                                 ($conf (index-atom $f 1))
                                 ($sc (fact-relevance $c $goal)))
                                (if (and (> $sc 0) (not (== (car-atom $c) episode)))
                                    ((- 0 $sc) (- 0 $conf) $c $conf)
                                    (empty))))
        (map-atom (take (sort-atom $scored) (config-value memory-top-k))
                  $x ((index-atom $x 2) (index-atom $x 3)))))

; past runs whose goal shares words with this one: ((GOAL TOOLS ANSWER) ...) best first, max 3
(= (similar-episodes $goal)
   (let $scored (collapse (let* (($e (match &kb (fact (episode $g $tl $a) (meta $s $t $conf)) ($g $tl $a $conf)))
                                 ($sc (py-call (text.overlap (index-atom $e 0) $goal))))
                                (if (> $sc 0) ((- 0 $sc) (- 0 (index-atom $e 3)) $e) (empty))))
        (map-atom (take (sort-atom $scored) 3) $x
                  (let $e (index-atom $x 2) ((index-atom $e 0) (index-atom $e 1) (index-atom $e 2))))))

; ---------------- size limit ----------------
(= (drop-weakest $list $k)
   (if (or (== $k 0) (== $list ()))
       0
       (let* (($c (index-atom (car-atom $list) 2))
              ($r (collapse (forget $c)))
              ($t (cdr-atom $list))
              ($k2 (- $k 1)))
             (+ 1 (drop-weakest $t $k2)))))

; lowest confidence first, oldest first among equals
(= (prune-memory)
   (let $excess (- (fact-count) (config-value memory-max))
        (if (<= $excess 0)
            0
            (drop-weakest (sort-atom (collapse (match &kb (fact $c (meta $s $t $conf)) ($conf $t $c))))
                          $excess))))

(= (memory-stats)
   (let* (($all (fact-count))
          ($eps (size-atom (collapse (match &kb (fact (episode $g $t $a) $m) $g))))
          ($gaps (size-atom (collapse (match &kb (fact (capability-gap $w) $m) $w)))))
         (memory facts $all episodes $eps capability-gaps $gaps)))
