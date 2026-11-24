; skills.metta — reusable procedures and how PeTTa picks them.
; Needs core/schema.metta.
;
;   !(declare-skill NAME "description" (TOOL ...) (KEYWORD ...))
;   !(set-skill-info NAME procedure|output|on-error "text")
;
; A skill is guidance for Gemini + the tools it needs. It runs through the
; normal agent loop, so every tool call still passes all tool gates.
;
; Atoms in &caps:
;   (skill NAME "desc")  (skill-needs NAME TOOL)  (skill-keywords NAME (k ...))
;   (skill-info NAME KEY "text")

!(import! &self "text.py")

(skill-info-key procedure)
(skill-info-key output)
(skill-info-key on-error)

(= (skill-known $s) (not (== (collapse (match &caps (skill $s $d) yes)) ())))

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

; ---------------- discovery ----------------
(= (skill-score $s $goal)
   (let $kws (collapse (match &caps (skill-keywords $s $k) $k))
        (if (== $kws ()) 0 (py-call (text.count_hits (car-atom $kws) $goal)))))

; Available skills whose keywords hit the goal, best first: (research math ...)
(= (relevant-skills $goal)
   (let $scored (collapse (let* (($s (match &caps (skill $n $d) $n))
                                 ($sc (skill-score $s $goal)))
                                (if (and (> $sc 0) (skill-available $s))
                                    ((- 0 $sc) $s)          ; negative → sort puts best first
                                    (empty))))
        (map-atom (sort-atom $scored) $p (index-atom $p 1))))

; Everything Gemini needs to follow a skill: (NAME "desc" ((procedure "..") (output "..")))
(= (skill-detail $s)
   (let $d (match &caps (skill $s $x) $x)
        ($s $d (collapse (match &caps (skill-info $s $k $v) ($k $v))))))

(= (relevant-skill-details $goal)
   (map-atom (relevant-skills $goal) $s (skill-detail $s)))
