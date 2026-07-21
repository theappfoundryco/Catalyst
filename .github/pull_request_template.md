<!-- Keep this short. A PR that explains why is easier to review than one that explains what — the diff already says what. -->

## What this changes

## Why

## How it was tested

<!--
Catalyst touches people's actual development environments — it uninstalls packages, edits shell
config, and runs privileged operations. "It builds" is not testing. Say what you ran and what
you saw.
-->

---

- [ ] I read [`docs/toAvoid.md`](../docs/toAvoid.md) and this doesn't reintroduce anything on that list
- [ ] Comments explain *why*, not *what* (see [`docs/Formrules.md`](../docs/Formrules.md))
- [ ] I didn't delete an existing explanatory comment without understanding what it protected
- [ ] New Swift files are registered in `project.pbxproj`, or I added the type to a file that already is
- [ ] I'm okay with this being licensed under GPLv3
