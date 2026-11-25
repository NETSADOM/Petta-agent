; skills.metta — reusable procedures and how PeTTa picks them.
; Needs core/schema.metta.
;
; Two ways to write a skill (both end up as the same atoms, same gates):
;
;   in MeTTa (short skills)
;     !(declare-skill NAME "description" (TOOL ...) (KEYWORD ...))
;     !(set-skill-info NAME procedure|output|on-error|guide "text")
;
;   as a folder (long skills)            !(load-skills "skills")
;     skills/NAME/SKILL.md     frontmatter (name, description, tools, keywords?)
;                              + a free Markdown guide of any length
;     skills/NAME/other.md     extra files, read only when needed: read-skill NAME/other.md
;
; A skill is guidance for the LLM + the tools it needs. It runs through the
; normal agent loop, so every tool call still passes all tool gates.
;
; Atoms in &caps:
;   (skill NAME "desc")  (skill-needs NAME TOOL)  (skill-keywords NAME (k ...))
;   (skill-info NAME KEY "text")  (skill-dir NAME "folder")  (skill-resources NAME ("f" ...))
;
; How the LLM gets skills (progressive disclosure, prompt stays small):
;   plan   every available skill (name + description), and the best matches
;          for the goal as SHORT summaries (skill-plan-chars)
;   act    the current task's skills IN FULL (skill-guide-chars), plus the list
;          of all skills: the model can load any of them with read-skill

!(import! &self "text.py")
!(import! &self "skill_files.py")

(skill-info-key procedure)
(skill-info-key output)
(skill-info-key on-error)
(skill-info-key guide)

!(set-config skill-plan-chars 600)     ; per recommended skill in the PLAN prompt
!(set-config skill-guide-chars 6000)   ; per skill of the current task in the ACT prompt
!(set-config skill-max-recommended 4)  ; recommended skills in the PLAN prompt

(= (skill-known $s) (not (== (collapse (match &caps (skill $s $d) yes)) ())))
(= (skill-names) (collapse (match &caps (skill $n $d) $n)))

(= (declare-skill $name $desc $tools $keywords)
   (if (skill-known $name)
       (error (duplicate-skill $name))
       (let* (($a (add-atom &caps (skill $name $desc)))
              ($b (collapse (let $t (superpose $tools) (add-atom &caps (skill-needs $name $t)))))
              ($c (add-atom &caps (skill-keywords $name $keywords))))
             (declared-skill $name))))

(= (set-skill-info $s $k $text)
   (if (not (skill-known $s))
       (error (unknown-skill $s))
       (if (== (collapse (match &self (skill-info-key $k) yes)) ())
           (error (invalid-skill-key $k))
           (let $removed (collapse (let $o (match &caps (skill-info $s $k $x) (skill-info $s $k $x))
                                        (remove-atom &caps $o)))
                (let $r (add-atom &caps (skill-info $s $k $text)) (skill-info-set $s $k))))))

; ---------------- skill folders ----------------
; → one result per folder: (loaded-skill NAME) | (error ...)
(= (load-skills $dir)
   (let $entries (sread (py-call (skill_files.load_dir $dir)))
        (collapse (let $e (superpose $entries) (load-skill-entry $e)))))

(= (load-skill-entry $e)
   (if (== (car-atom $e) skill-file-error)
       (error (bad-skill-folder (index-atom $e 1) (index-atom $e 2)))
       (let* (($name (index-atom $e 1))
              ($r (declare-skill $name (index-atom $e 2) (index-atom $e 3) (index-atom $e 4))))
             (if (== (car-atom $r) declared-skill)
                 (let* (($g (set-skill-info $name guide (index-atom $e 5)))
                        ($dir (index-atom $e 6))          ; add-atom does not evaluate:
                        ($files (index-atom $e 7))        ; bind first
                        ($d (add-atom &caps (skill-dir $name $dir)))
                        ($f (add-atom &caps (skill-resources $name $files))))
                       (loaded-skill $name))
                 $r))))

(= (skill-files $s)
   (let $r (collapse (match &caps (skill-resources $s $x) $x))
        (if (== $r ()) () (car-atom $r))))

(= (skill-folder $s)
   (let $r (collapse (match &caps (skill-dir $s $x) $x))
        (if (== $r ()) none (car-atom $r))))

; ---------------- discovery ----------------
; keywords (optional) + the words of the name and description, lightly stemmed
; (calculating ~ calculate, files ~ file), so a skill without keywords is found too
(= (skill-score $s $goal)
   (let* (($kws (collapse (match &caps (skill-keywords $s $k) $k)))
          ($d (match &caps (skill $s $x) $x)))
         (py-call (text.skill_score (if (== $kws ()) () (car-atom $kws)) $s $d $goal))))

; Available skills that fit the goal, best first: (research math ...)
(= (relevant-skills $goal)
   (let $scored (collapse (let* (($s (match &caps (skill $n $d) $n))
                                 ($sc (skill-score $s $goal)))
                                (if (and (> $sc 0) (skill-available $s))
                                    ((- 0 $sc) $s)          ; negative → sort puts best first
                                    (empty))))
        (map-atom (sort-atom $scored) $p (index-atom $p 1))))

(= (top-skills $goal)
   (let $all (relevant-skills $goal)
        (if (> (size-atom $all) (config-value skill-max-recommended))
            (collapse (let $i (superpose (0 1 2 3 4 5 6 7 8 9))
                           (if (< $i (config-value skill-max-recommended)) (index-atom $all $i) (empty))))
            $all)))

; Everything the LLM needs to follow a skill: (NAME "desc" ((procedure "..") (output "..")))
(= (skill-detail $s)
   (let $d (match &caps (skill $s $x) $x)
        ($s $d (collapse (match &caps (skill-info $s $k $v) ($k $v))))))

(= (relevant-skill-details $goal)
   (map-atom (relevant-skills $goal) $s (skill-detail $s)))

; + its extra files, for the prompt renderer (skill_files.render)
(= (skill-view $s)
   (let ($n $d $infos) (skill-detail $s) ($n $d $infos (skill-files $s))))

(= (skill-views $skills) (map-atom $skills $s (skill-view $s)))

; the PLAN prompt's recommendations: short summaries of the best matches
(= (recommended-skills-text $goal)
   (py-call (skill_files.render (skill-views (top-skills $goal)) (config-value skill-plan-chars))))
