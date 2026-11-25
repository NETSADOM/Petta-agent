; Tests: the knowledge schema and the reasoning rules over it.

!(import! &self ../core/store)
!(import! &self ../core/schema)

; ---------------- &caps: tools and skills ----------------
!(add-atom &caps (tool calc "evaluate arithmetic" safe))
!(add-atom &caps (tool write-file "write a file" needs-approval))
!(add-atom &caps (skill math "solve math problems"))
!(add-atom &caps (skill-needs math calc))
!(add-atom &caps (skill research "look things up"))
!(add-atom &caps (skill-needs research web-search))   ; web-search not declared

!(test (allowed calc) True)
!(test (allowed write-file) False)
!(test (allowed rm-rf) False)                          ; unknown → denied
!(test (needs-approval write-file) True)
!(test (needs-approval calc) False)
!(test (missing-tools research) (web-search))
!(test (skill-available math) True)
!(test (skill-available research) False)
!(test (skill-catalog) ((math "solve math problems")))  ; research hidden
!(test (size-atom (tool-catalog)) 2)

; ---------------- &kb: facts with metadata ----------------
!(remember (capital france paris) user 0.8)
!(remember (capital japan tokyo) web 0.9)
!(test (recall (capital france $x)) (((capital france paris) 0.8)))
!(test (fact-count) 2)

; remembering the same content again updates it, no duplicate
!(remember (capital france paris) web 0.95)
!(test (recall (capital france $x)) (((capital france paris) 0.95)))
!(test (fact-count) 2)
!(test (match &kb (fact (capital france paris) (meta $s $t $c)) $s) web)

; pattern recall across facts
!(test (size-atom (recall (capital $c $city))) 2)

; forget
!(collapse (forget (capital japan tokyo)))
!(test (recall (capital japan $x)) ())

; persistence of facts with metadata (reload checked in test_schema_reload)
!(test (save-space &kb "data/test_schema_kb.metta") 1)

; ---------------- &wm: goal and tasks ----------------
!(set-goal "find the population of paris and double it")
!(set-goal "find the population of paris and triple it")   ; replaces
!(test (collapse (match &wm (goal $g) $g)) ("find the population of paris and triple it"))

!(add-task t1 "search population")
!(add-task t2 "multiply by 3")
!(add-task t3 "write report")
!(add-dependency t2 t1)
!(add-dependency t3 t2)

!(test (status-of t1) pending)
!(test (ready-tasks) (t1))                  ; t2, t3 wait on dependencies
!(test (is-ready t2) False)

!(set-status t1 running)
!(set-status t1 completed)
!(test (ready-tasks) (t2))                  ; t1 done → t2 unlocked
!(test (all-done) False)

!(test (set-status t2 finished) (error invalid-status finished))
!(test (status-of t2) pending)              ; unchanged after bad status

!(set-status t2 failed)
!(test (is-blocked t3) True)                ; its dependency failed
!(test (is-blocked t2) False)
!(test (ready-tasks) ())

!(set-status t2 completed)
!(set-status t3 cancelled)
!(test (all-done) True)
!(test (size-atom (collapse (match &wm (task $i $d $s) $i))) 3)   ; no duplicates

; ---------------- &wm: steps and loop guard ----------------
!(record-step calc "2+2" (ok 4))
!(record-step web-search "paris" (error timeout))
!(test (stuck web-search "paris") False)    ; one failure: ok to retry
!(record-step web-search "paris" (error timeout))
!(test (stuck web-search "paris") True)     ; two identical failures: stop
!(test (stuck calc "2+2") False)
!(test (step-count) 3)
!(test (match &wm (step 3 $t $i $o) $o) (error timeout))
