# FAIL-001: Non-English Output in Project and User-Facing Text

## Status

Resolved (recurring — required three user corrections)

## Date

2026-10-01

## Phase

Phase 0 → Phase 1

## Attempt

Produce Phase 0 audit documentation and Phase 1 progress narration in the project's
working language (English).

## Observed Behaviour

The agent emitted Chinese for both persistent project content and live progress
narration — for example progress lines such as `现在让我来创建所有的 Phase 1 源文件。`
("Now let me create all the Phase 1 source files").

> **Note for automated English-only audits:** the Chinese text above is a deliberate
> verbatim quotation of the failure being documented. It is evidence, not output. This is
> the only non-Latin content permitted in the engineering documentation, and it exists
> because the engineering workflow forbids erasing failures from the record.

The user had to correct this **three separate times**, each time restating that all
output must be English. Two of those corrections arrived as explicit stop-work
instructions.

## Evidence

User corrections (verbatim, in order):

1. "Translate the entire existing Phase 0 Clean-Start Audit report into English. ...
   From this point forward, **ALL PixelDesktop project-facing output MUST ALWAYS be in
   English.**"
2. "STOP and correct the language behavior before continuing Phase 1. You are currently
   producing Chinese progress narration such as: `现在让我来创建所有的 Phase 1 源文件。`"
3. "Your output has switched to Chinese again. STOP using Chinese immediately. This is a
   strict project requirement: **ALL HERMES USER-FACING OUTPUT MUST BE IN ENGLISH.**"

The English-only rule also appears in the project's standing constraints.

## Diagnosis

Classification: **model behaviour**, not architecture, tooling, or environment.

The underlying model (`meituan/longcat-2.5-preview:free`) generates Chinese
interstitial text. The defect is that this text was **emitted directly** rather than
being normalized to the project's working language first.

Two distinct failure surfaces were involved:

- **Persistent content** — text written into audit reports and documentation files.
- **Live narration** — progress and status text shown to the user.

The user's correction explicitly covered both, because translating only the final
report would still leave Chinese narration in the working session.

A second-order problem made this worse: correcting one surface (documents) did not fix
the other (narration), so the same defect reappeared after being "fixed".

## Correction

1. Audit all previously created project documentation for non-English content and
   translate it, preserving findings, evidence, paths, and issue IDs unchanged.
2. Treat English as a **normalization step applied before emission**, not as a property
   of the source text. If the model produces another language internally, translate
   before the text reaches a file, Multica, Discord, or the user.
3. Apply the rule to every output surface: phase reports, ADRs, engineering logs, AI
   development logs, Multica issues and comments, commit messages, code comments,
   Discord messages, progress narration, and status updates.
4. Do not translate code identifiers, API names, file paths, commands, model names, or
   package names.

## Result

- Phase 0 audit and Phase 1 documentation verified English-only via a character-range
  check for CJK codepoints.
- Phase 2 work in this session produced English-only content.

## Lesson

**Language normalization is an output-stage responsibility, not an input-stage
assumption.** When a model's default output language differs from the project's working
language, every emission path needs the normalization applied — including narration,
which is easy to overlook because it leaves no artifact to inspect afterwards.

Corollary: **a rule stated once is not a rule implemented.** The correction was
understood and acknowledged on the first pass and still recurred twice. An
acknowledgement is not evidence of compliance; only the output is.

## What Should Future Agents Do Differently

- Before emitting text, check whether it is in the project's working language. If not,
  translate it — do not emit it with the expectation of fixing it later.
- Treat live narration as a first-class output surface. It has no artifact, so it is
  never caught by a post-hoc documentation audit.
- When a user states a standing constraint emphatically and more than once, treat
  recurrence as a process defect to be designed out, not as an attention lapse.
