; store.metta — save and restore a whole space to a text file.
;
;   !(save-space &kb "data/kb.metta")   -> number of atoms written
;   !(load-space &kb "data/kb.metta")   -> number of atoms restored
;
; Verified gotchas (see README):
;   - add-atom does NOT evaluate its argument, so sread is bound with let* first.
;   - superpose does NOT evaluate its argument, so the list is bound first too.

!(import! &self "store.py")

(= (save-space $space $path)
   (let $lines (map-atom (collapse (get-atoms $space)) $a (repr $a))
        (py-call (store.save_lines $path $lines))))

; Restores one atom per nondeterministic branch.
(= (restore-each $space $path)
   (let* (($lines (py-call (store.load_lines $path)))
          ($line  (superpose $lines))
          ($atom  (sread $line)))
         (add-atom $space $atom)))

; Collapses all branches and returns how many atoms were restored.
(= (load-space $space $path)
   (size-atom (collapse (restore-each $space $path))))
