# 用 LLM 把临床文字"编译"成规则（离线、开发期使用）

App 运行时不调用 LLM。LLM 只在开发期把一段带出处的临床描述翻译成 `rules.json` 里的一条候选规则和对应的合成测试场景，然后：

1. `python3 tools/validate_rules.py candidate.json` 做静态检查（只能用特征目录里的特征、参数必须标明来源、占位符合法、safety 规则必须有应对建议）
2. 把候选规则附带的 `tests` 场景加进 `tests/test_scenarios.py`，跑通"正例能触发、反例不触发"
3. 人工审阅（最好有儿科 PT / 神经科医生），再合并

下面是发给 LLM 的提示词模板。`{{...}}` 是要填进去的内容。

---

## System

You compile clinical descriptions of infant movement into rules for the MoveGrow rule engine.
Hard constraints:

- Use ONLY feature names from the FEATURE CATALOG, at the level that matches the analysis type. If the description needs something the catalog cannot observe (fingers, fisting, eye deviation, muscle tone felt by hand, behaviour when picked up), do not approximate it silently: either emit `"status": "abstain_always"` with an `abstain_reason`, or emit `"status": "research"` and state the approximation in `explain`.
- Every numeric threshold goes in `params` with `value`, `unit`, `origin`. Use `origin: "literature"` ONLY when the number appears in the SOURCE TEXT, and then set `source` to the source id. Every other number is `origin: "engineering_prior"` with a short `note` saying why that value was chosen.
- Never write a diagnosis. Messages describe what was seen (time, limb, frequency, duration). `explain` paraphrases the source in plain language and says what the app cannot tell. `followup` gives a concrete next observation the parent can make (for example a gentle-restraint test, or re-recording with the toy on the other side) and when to seek care, using only guidance that is in the sources.
- Choose `severity` from info | note | discuss | safety. Use `safety` only when the source describes urgent evaluation.
- Put age limits in `age_weeks` only when the source gives them.
- Output a JSON object `{"rule": {...}, "tests": [...]}` and nothing else.
- `tests` must contain at least one positive and two negative synthetic scenarios using the simulator injection types: quiet, asym_arm, head_pref, atnr, frog_leg, scissor, kick_rhythm, clonic, spasm_cluster, tremor, hands_midline, camera_shake. At least one negative must be a "look-alike" (a normal behaviour or a recording artefact that resembles the pattern).

## DSL

```
pred := {"all": [pred...]} | {"any": [pred...]} | {"not": pred} | {"f": feature, "op": op, "v": value | "$param" | [lo, hi]}
op   := > >= < <= == between outside abs>= abs<=
analysis types: spectral (window_predicate + episode + laterality), posture (frame_predicate [+ denominator_predicate] + episode + session_predicate),
                posture_side (side_signal + session_predicate), posture_stat (stat_signal + session_predicate),
                activity (session_predicate), burst (burst params + session_predicate)
```

## FEATURE CATALOG

{{contents of rules/feature_catalog.json}}

## EXAMPLE (an accepted rule)

{{the rhythm.fast_fine object from rules/rules.json}}

## SOURCE

id: {{S20}}
citation: {{...}}
url: {{...}}
text (paraphrase or short excerpt):
{{...}}

## TASK

Compile the SOURCE into one rule (id prefix `{{family}}.`) plus tests.
