"""Rebuild the read-only PostgreSQL screening templates. No database connection.

Only {{schema}} is substituted by the runner, using a validated identifier.
All concept sets are discovery candidates, not validated phenotypes.
"""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "sql"
MANIFEST = []

MV = [1243692,2008006,2008007,2008008,2008009,2108681,3655902,4039922,
      4055375,4055376,4074666,4177224,37152408,37152409,37152410,37152411,
      37152412,37157165,37157166,37158404,37158487,40486624]
INTUB = [765576,3657544,4013354,4058031,4119642,4179373,4228313,4303945,
         4335481,4335583,4335584,4337045,4337615,4337616,4337617,4339623,
         37206251,44515633]
FLUID = {
    "IN_IV":[4090200,3037253,3035591,3037775],
    "IN_NUTRITION":[21491171,37153230],
    "IN_ENTERAL_ORAL":[21491169,3012677,3002791,3020617,3017465,3014013,
                       21491170,3010494,21493071,21493079,37311741],
    "OUT_URINE":[21491173,21493221,3016267,3008828,3008071,3018727,3014835,3014315,4264378],
    "OUT_DRAIN":[40484209,4090194,3006376,3026556,3023454,3025727,3017152,
                 3037836,21491180,21491181,21491183,21491184,21491185],
    "OUT_BLOOD":[3021505,3016687,21493943,4354266,3009631],
    "OUT_RRT":[1989402,1988590,1989626,1988731,4139443],
    "OUT_TOTAL_OTHER":[3018366,3012848,3008540,3020433,3028277],
}

RRT_PROVIDER_BOILERPLATE_PATTERN = (
    r"(^|[^a-z])health[[:space:]-]*care[[:space:]-]+"
    r"(professionals?|providers?|practitioners?)([^a-z]|$)"
)
RRT_CONTEXT_PATTERN = (
    r"(^|[^a-z])(comments?|(?:re)?assess(?:ment|ments|ed|ing)?|"
    r"monitor(?:ing|ed|s)?|care|aftercare|history|status|clearance|flow|pressure)([^a-z]|$)"
)

TOPICS = {
 "transfusion": {
  "pattern":r"transfus|packed.{0,15}red.{0,15}(cell|blood)|fresh.{0,10}frozen.{0,10}plasma|cryoprecip|platelet.{0,25}(administr|volume|unit)|blood.{0,15}(product|component)",
  "seeds":{},
  "kind": """CASE WHEN c.concept_name ~* 'crossmatch|compatib|screen|order|prepar|request|issue' THEN 'planning_or_compatibility'
    WHEN c.concept_name ~* 'platelet' THEN 'platelet_candidate'
    WHEN c.concept_name ~* 'cryoprecip' THEN 'cryoprecipitate_candidate'
    WHEN c.concept_name ~* 'plasma' THEN 'plasma_candidate'
    WHEN c.concept_name ~* 'red.{0,15}(cell|blood)|erythrocyte' THEN 'rbc_candidate'
    ELSE 'transfusion_unspecified' END""",
  "review":"Verify actual administration versus order, issue or crossmatch; product component, adult units versus pediatric mL, administered volume, and ICU overlap. Quantity alone is not administered volume."
 },
 "microbiology_ast": {
  "pattern":r"culture|microbiolog|susceptib|antibiotic.{0,20}sensitiv|minimum.{0,12}inhibitory|(^|[^a-z])mic([^a-z]|$)|organism.{0,20}(identif|isolat)|species.{0,10}identif",
  "seeds":{},
  "extra":"OR c.concept_class_id ~* '^organism$'",
  "kind":"""CASE WHEN c.concept_name ~* 'susceptib|antibiotic.{0,20}sensitiv|minimum.{0,12}inhibitory|(^|[^a-z])mic([^a-z]|$)' THEN 'ast_candidate'
    WHEN c.concept_name ~* 'positive.{0,25}(blood.{0,10})?culture|culture.{0,40}(panel|molecular|nucleic|pcr)' THEN 'reflex_or_molecular_candidate'
    WHEN c.concept_name ~* 'blood.{0,40}culture|culture.{0,40}blood' THEN 'blood_culture_candidate'
    WHEN c.concept_class_id ~* '^organism$' THEN 'organism_value_candidate'
    ELSE 'other_microbiology_candidate' END""",
  "review":"Separate primary cultures from reflex or molecular panels and repeat tests; reconcile organism-only results, negatives, contamination and specimen-isolate-antibiotic endpoints. No clinical positivity is inferred by this pack."
 },
 "continuous_infusions": {
  "pattern":r"norepinephrine|noradrenaline|propofol|levophed|diprivan",
  "seeds":{"norepinephrine":[1321341],"propofol":[753626]},
  "kind":"CASE WHEN c.concept_name ~* 'norepinephrine|noradrenaline|levophed' THEN 'norepinephrine' WHEN c.concept_name ~* 'propofol|diprivan' THEN 'propofol' ELSE 'drug_candidate' END",
  "review":"Verify administration provenance, rate versus total quantity, concentration, weight normalization, bag changes, bolus exclusion and episode rules. Adjacent or overlapping rows do not establish continuous treatment."
 },
 "mechanical_ventilation": {
  "pattern":r"mechanical.{0,20}ventilat|invasive.{0,20}ventilat|artificial.{0,20}ventilat|ventilator|intubat|extubat|positive.{0,12}end.{0,12}expiratory|tidal.{0,10}volume|fraction.{0,15}inspired.{0,10}oxygen|(^|[^a-z])(fio2|peep|cpap|bipap)([^a-z]|$)",
  "seeds":{"mv_seed_candidate":MV,"intubation_candidate":INTUB},
  "kind":"""CASE WHEN c.concept_name ~* 'extubat' THEN 'extubation_candidate'
    WHEN c.concept_name ~* 'intubat' THEN 'intubation_candidate'
    WHEN c.concept_name ~* 'non.?invasive|cpap|bipap' THEN 'noninvasive_candidate'
    WHEN c.concept_name ~* 'tidal|peep|fio2|inspired.{0,10}oxygen|end.{0,12}expiratory' THEN 'setting_candidate'
    WHEN c.concept_name ~* 'invasive' THEN 'invasive_candidate'
    ELSE 'ventilation_unspecified_candidate' END""",
  "review":"Validate invasive versus noninvasive support, intubation/extubation times and episodes. Airway procedures, FiO2, PEEP or a ventilator device alone do not prove mechanical ventilation."
 },
 "code_status": {
  "pattern":r"code.{0,3}status|full.{0,3}code|resuscitation.{0,15}(status|preference|order)|do.{0,3}not.{0,3}(resuscitat|intubat)|not.{0,3}for.{0,3}(resuscitat|intubat)|(^|[^a-z])(dnr|dni)([^a-z]|$)|limited.{0,3}(code|resuscitat)|partial.{0,3}code|allow.{0,3}natural.{0,3}death|advance.{0,3}directive",
  "seeds":{"DNI":[3175080],"DNR":[4119499],"DNR_DNI_LIMITED":[3172086],"FULL_CODE":[3172879]},
  "kind":"""CASE WHEN c.concept_name ~* 'dnr.{0,20}dni|dni.{0,20}dnr|resuscitat.{0,40}intubat|limited.{0,3}(code|resuscitat)|partial.{0,3}code' THEN 'DNR_DNI_LIMITED'
    WHEN c.concept_name ~* 'do.{0,3}not.{0,3}intubat|not.{0,3}for.{0,3}intubat|(^|[^a-z])dni([^a-z]|$)' THEN 'DNI'
    WHEN c.concept_name ~* 'do.{0,3}not.{0,3}resuscitat|not.{0,3}for.{0,3}resuscitat|(^|[^a-z])dnr([^a-z]|$)|allow.{0,3}natural.{0,3}death' THEN 'DNR'
    WHEN c.concept_name ~* 'full.{0,3}code|full.{0,3}resuscitat|all.{0,20}resuscitative.{0,10}measure' THEN 'FULL_CODE'
    ELSE 'GENERIC_CODE_STATUS' END""",
  "review":"Preserve DNR, DNI, combined/limited and full-code distinctions. Standard/source/value conflicts require manual review. Repeated records are not status changes; candidate transitions are not validated clinical changes."
 },
 "fluid_balance": {
  "pattern":r"fluid.{0,10}(intake|input|output|balance)|oral.{0,20}intake|enteral.{0,25}(intake|volume|formula)|tube.{0,25}(intake|feeding|output)|formula.{0,10}intake|parenteral.{0,20}(fluid|nutrition)|urine.{0,10}output|blood.{0,10}loss|ultrafiltrat.{0,25}(remov|output)|body.{0,5}weight|patient.{0,5}weight",
  "seeds":FLUID,
  "kind":"""CASE WHEN c.concept_name ~* 'body.{0,5}weight|patient.{0,5}weight' THEN 'WEIGHT'
    WHEN c.concept_name ~* 'balance' THEN 'BALANCE'
    WHEN c.concept_name ~* 'urine.{0,10}output' THEN 'OUT_URINE'
    WHEN c.concept_name ~* 'ultrafiltrat|dialysis.{0,25}(remov|output)' THEN 'OUT_RRT'
    WHEN c.concept_name ~* 'blood.{0,10}loss' THEN 'OUT_BLOOD'
    WHEN c.concept_name ~* 'output|drain' THEN 'OUT_TOTAL_OTHER'
    WHEN c.concept_name ~* 'parenteral.{0,20}nutrition' THEN 'IN_NUTRITION'
    WHEN c.concept_name ~* 'oral|enteral|formula|feeding' THEN 'IN_ENTERAL_ORAL'
    WHEN c.concept_name ~* 'intake|input|parenteral' THEN 'IN_IV'
    ELSE 'UNCLASSIFIED_FLUID' END""",
  "review":"Validate measured volume versus rate, interval versus cumulative totals, total-versus-component overlap, charting day/time zone and missing output. No volume summation or net balance is computed. Seed concepts inherited from the supplied source material need site vocabulary review."
 },
 "dialysis_rrt": {
  "pattern":r"dialysis|ha?emofiltrat|ha?emodiafiltrat|(renal|kidney).{0,5}replacement|(^|[^a-z])(crrt|ckrt|cvvh|cvvhd|cvvhdf)([^a-z]|$)|ultrafiltrat.{0,25}(remov|target|volume)|fluid.{0,20}(removed|removal)|desired.{0,5}fluid.{0,5}loss",
  "exclude":"AND c.concept_name !~* 'culture|microbiolog|bacteri|susceptib'",
  "seeds":{"removal_seed_candidate":[1989402,1988590,1989626,1988731,4139443]},
  "kind":f"""CASE WHEN c.concept_name ~* 'target|prescri|desired|to.{{0,3}}be.{{0,3}}removed' THEN 'target_removal_candidate'
    WHEN c.concept_name ~* 'removed|fluid.{{0,10}}output|ultrafiltrat.{{0,15}}remov' THEN 'actual_removal_candidate'
    WHEN c.concept_name ~* 'catheter|access|fistula|preoperative' THEN 'access_candidate'
    WHEN REGEXP_REPLACE(c.concept_name, '{RRT_PROVIDER_BOILERPLATE_PATTERN}', ' ', 'gi')
         ~* '{RRT_CONTEXT_PATTERN}' THEN 'documentation_or_monitoring_candidate'
    WHEN c.concept_name ~* 'continuous|crrt|ckrt|cvvh' THEN 'continuous_rrt_candidate'
    WHEN c.concept_name ~* 'peritoneal' THEN 'peritoneal_dialysis_candidate'
    ELSE 'other_rrt_candidate' END""",
  "review":"Separate direct treatment from access and monitoring; actual removed fluid from prescribed targets. Same-visit co-occurrence is not session linkage. No dialysis indication, AKI phenotype or session count is inferred."
 },
}

DOMAINS = {
 "measurement":dict(id="measurement_id",concept="measurement_concept_id",source="measurement_source_concept_id",value="value_as_concept_id",date="measurement_date",dt="measurement_datetime",num="value_as_number",unit="unit_concept_id",unit_source="unit_source_value",type="measurement_type_concept_id",event="measurement_event_id",event_field="meas_event_field_concept_id"),
 "observation":dict(id="observation_id",concept="observation_concept_id",source="observation_source_concept_id",value="value_as_concept_id",date="observation_date",dt="observation_datetime",num="value_as_number",unit="unit_concept_id",unit_source="unit_source_value",type="observation_type_concept_id",event="observation_event_id",event_field="obs_event_field_concept_id"),
 "procedure_occurrence":dict(id="procedure_occurrence_id",concept="procedure_concept_id",source="procedure_source_concept_id",date="procedure_date",dt="procedure_datetime",end="procedure_end_datetime",num="quantity",type="procedure_type_concept_id"),
 "drug_exposure":dict(id="drug_exposure_id",concept="drug_concept_id",source="drug_source_concept_id",date="drug_exposure_start_date",dt="drug_exposure_start_datetime",end="drug_exposure_end_datetime",num="quantity",unit_source="dose_unit_source_value",type="drug_type_concept_id"),
 "device_exposure":dict(id="device_exposure_id",concept="device_concept_id",source="device_source_concept_id",date="device_exposure_start_date",dt="device_exposure_start_datetime",end="device_exposure_end_datetime",num="quantity",unit="unit_concept_id",unit_source="unit_source_value",type="device_type_concept_id"),
 "condition_occurrence":dict(id="condition_occurrence_id",concept="condition_concept_id",source="condition_source_concept_id",date="condition_start_date",dt="condition_start_datetime",end="condition_end_datetime",type="condition_type_concept_id"),
}

def lit(value):
    return "'" + str(value).replace("'", "''") + "'"

def concept_cte(topic):
    t=TOPICS[topic]
    pairs=[f"({n}, {lit(k)})" for k,ns in t["seeds"].items() for n in ns]
    seed = "VALUES " + ", ".join(pairs) if pairs else "SELECT NULL::integer, NULL::text WHERE FALSE"
    return f"""seed(concept_id, seed_kind) AS ({seed}),
candidate_concepts AS MATERIALIZED (
    SELECT c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id,
           c.standard_concept, c.concept_class_id, c.concept_code,
           s.concept_id IS NOT NULL AS inherited_seed,
           COALESCE(s.seed_kind, {t['kind']}) AS candidate_kind
    FROM {{{{schema}}}}.concept c
    LEFT JOIN seed s ON s.concept_id = c.concept_id
    WHERE c.concept_id <> 0 AND c.invalid_reason IS NULL
      AND (s.concept_id IS NOT NULL OR c.concept_name ~* {lit(t['pattern'])} {t.get('extra','')})
      {t.get('exclude','')}
)"""

def candidate_cte(topic, table, name="candidate_rows"):
    d=DOMAINS[table]
    value = "cv.concept_id IS NOT NULL" if d.get("value") else "FALSE"
    vc = "cv.candidate_kind" if d.get("value") else "NULL::text"
    vjoin = f"LEFT JOIN candidate_concepts cv ON cv.concept_id = d.{d['value']}" if d.get("value") else ""
    vwhere = f"OR d.{d['value']} IN (SELECT concept_id FROM candidate_concepts)" if d.get("value") else ""
    return f"""{name} AS MATERIALIZED (
    SELECT d.*, cs.concept_id IS NOT NULL AS standard_match,
           cc.concept_id IS NOT NULL AS source_match, {value} AS value_match,
           cs.candidate_kind AS standard_kind, cc.candidate_kind AS source_kind,
           {vc} AS value_kind
    FROM {{{{schema}}}}.{table} d
    LEFT JOIN candidate_concepts cs ON cs.concept_id = d.{d['concept']}
    LEFT JOIN candidate_concepts cc ON cc.concept_id = d.{d['source']}
    {vjoin}
    WHERE d.{d['concept']} IN (SELECT concept_id FROM candidate_concepts)
       OR d.{d['source']} IN (SELECT concept_id FROM candidate_concepts)
       {vwhere}
)"""

def ratio_row(variable, numerator, denominator="n"):
    result=f"({numerator})::text" if denominator is None else f"CASE WHEN ({denominator}) = 0 THEN NULL::text ELSE ROUND(100.0 * ({numerator}) / NULLIF(({denominator}),0),2)::text || '%' END"
    return f"({lit(variable)}, {result}, ({numerator})::numeric, {('NULL' if denominator is None else '('+denominator+')')}::numeric)"

def note_row(variable, text):
    return f"({lit(variable)}, {lit(text)}::text, NULL::numeric, NULL::numeric)"

def finish(category, ctes, metrics, from_clause="stats"):
    return "WITH\n"+ctes+f"\nSELECT {lit(category)}::text AS category, v.variable, v.result, v.numerator, v.denominator\nFROM {from_clause}\nCROSS JOIN LATERAL (VALUES\n    "+",\n    ".join(metrics)+"\n) AS v(variable, result, numerator, denominator)\nORDER BY variable;\n"

def emit(id, topic, tables, sql, description):
    path=f"sql/{id}.sql"
    header="-- PostgreSQL 12+, OMOP CDM 5.4. READ ONLY; aggregate output only.\n-- Discovery screen, not a validated phenotype. Zero hits mean not detected under this screen.\n-- Regex discovery is limited to CONCEPT; clinical source text is never scanned before candidate filtering.\n"
    (ROOT/path).write_text(header+sql,encoding="utf-8")
    MANIFEST.append(dict(id=id,topic=topic,path=path,required_tables=sorted(set(tables)),description=description))

def discovery(topic):
    ctes=concept_cte(topic)+""",
stats AS (
 SELECT COUNT(*) AS n,
        COUNT(*) FILTER (WHERE standard_concept = 'S') AS standard_n,
        COUNT(*) FILTER (WHERE inherited_seed) AS seed_n,
        (SELECT COUNT(*) FROM seed) AS seed_total,
        COUNT(DISTINCT vocabulary_id) AS vocabulary_n,
        COUNT(DISTINCT domain_id) AS domain_n,
        (SELECT STRING_AGG(concept_id::text || ': ' || concept_name || ' [' || domain_id || '; ' || vocabulary_id || ']', '; ' ORDER BY concept_id)
         FROM (SELECT * FROM candidate_concepts WHERE inherited_seed ORDER BY concept_id LIMIT 100) s) AS seed_metadata
 FROM candidate_concepts
)"""
    rows=[ratio_row("candidate_concepts","n",None),ratio_row("standard_candidate_concepts","standard_n"),
          ratio_row("inherited_seeds_present_and_valid","seed_n","seed_total"),ratio_row("candidate_vocabularies","vocabulary_n",None),
          ratio_row("candidate_domains","domain_n",None),note_row("concept_validation_status","DISCOVERY_ONLY. Inherited seeds and name matches require review against installed vocabulary and clinical meaning. No validated phenotype is supplied."),
          "('inherited_seed_metadata', COALESCE(seed_metadata,'No inherited seed found'), NULL::numeric, NULL::numeric)",
          note_row("semantic_review_required",TOPICS[topic]["review"])]
    emit(f"{topic}_concept_discovery",topic,["concept"],finish(topic+" / concept discovery",ctes,rows),"Inspect vocabulary candidate availability and inherited seed coverage before interpreting clinical counts.")

def generic(topic,table):
    d=DOMAINS[table]
    stats=["COUNT(*) AS n","COUNT(DISTINCT person_id) AS patients_n",
           "COUNT(*) FILTER (WHERE standard_match) AS standard_n",
           "COUNT(*) FILTER (WHERE source_match) AS source_n",
           "COUNT(*) FILTER (WHERE value_match) AS value_n",
           "COUNT(*) FILTER (WHERE source_match AND NOT standard_match) AS source_only_n",
           f"COUNT(*) FILTER (WHERE {d['concept']} IS NULL OR {d['concept']} = 0) AS unmapped_n",
           f"COUNT(*) FILTER (WHERE {d['dt']} IS NOT NULL) AS datetime_n",
           f"COUNT(*) FILTER (WHERE {d['dt']} IS NOT NULL AND {d['dt']}::time = TIME '00:00:00') AS midnight_n",
           f"COUNT(*) FILTER (WHERE {d['dt']}::date <> {d['date']}) AS date_mismatch_n",
           "COUNT(*) FILTER (WHERE visit_occurrence_id IS NOT NULL) AS visit_n",
           "COUNT(*) FILTER (WHERE visit_detail_id IS NOT NULL) AS detail_n",
           f"COUNT(*) FILTER (WHERE {d['type']} IS NOT NULL AND {d['type']} <> 0) AS type_n"]
    rows=[ratio_row("candidate_records","n",None),ratio_row("candidate_patients","patients_n",None),
          ratio_row("standard_concept_match","standard_n"),ratio_row("source_concept_match","source_n"),
          ratio_row("value_concept_match","value_n"),ratio_row("source_only_concept_match","source_only_n"),
          ratio_row("unmapped_standard_concept","unmapped_n"),ratio_row("with_datetime","datetime_n"),
          ratio_row("midnight_among_datetimes","midnight_n","datetime_n"),ratio_row("date_datetime_disagreement","date_mismatch_n","datetime_n"),
          ratio_row("with_visit_id","visit_n"),ratio_row("with_visit_detail_id","detail_n"),ratio_row("with_type_concept","type_n")]
    if d.get("num"):
        col=d['num']; stats += [f"COUNT(*) FILTER (WHERE {col} IS NOT NULL) AS numeric_n",f"COUNT(*) FILTER (WHERE {col} < 0) AS negative_n",f"COUNT(*) FILTER (WHERE {col} = 0) AS zero_n"]
        name="with_numeric_value" if col=="value_as_number" else "with_quantity"
        rows += [ratio_row(name,"numeric_n"),ratio_row("negative_numeric_value","negative_n","numeric_n"),ratio_row("zero_numeric_value","zero_n","numeric_n")]
    if d.get("unit"):
        col=d['unit']; stats += [f"COUNT(*) FILTER (WHERE {col} IS NOT NULL AND {col} <> 0) AS unit_n"]
        rows += [ratio_row("with_unit_concept","unit_n")]
        stats += [f"COUNT(*) FILTER (WHERE {col} IN (SELECT concept_id FROM {{{{schema}}}}.concept WHERE invalid_reason IS NULL AND (LOWER(concept_code) IN ('ml','l','ul','dl','[foz_us]') OR LOWER(concept_name) IN ('milliliter','liter','microliter','deciliter')))) AS volume_unit_n"]
        rows += [ratio_row("volume_unit_concept_candidate","volume_unit_n")]
        if d.get("num"):
            stats += [f"COUNT(*) FILTER (WHERE {d['num']} IS NOT NULL AND {col} IS NOT NULL AND {col} <> 0 AND {d['dt']} IS NOT NULL AND visit_occurrence_id IS NOT NULL) AS joint_n"]
            rows += [ratio_row("numeric_unit_datetime_visit_jointly_complete","joint_n")]
    if d.get("unit_source"):
        col=d['unit_source']; stats += [f"COUNT(*) FILTER (WHERE NULLIF(TRIM({col}), '') IS NOT NULL) AS unit_source_n"]
        rows += [ratio_row("with_unit_source_value","unit_source_n")]
    if d.get("end"):
        start=d['dt']; end=d['end']
        stats += [f"COUNT(*) FILTER (WHERE {start} IS NOT NULL AND {end} IS NOT NULL) AS pair_n",
                  f"COUNT(*) FILTER (WHERE {end} > {start}) AS duration_positive_n",
                  f"COUNT(*) FILTER (WHERE {end} = {start}) AS duration_zero_n",
                  f"COUNT(*) FILTER (WHERE {end} < {start}) AS duration_reversed_n"]
        rows += [ratio_row("with_complete_datetime_pair","pair_n"),ratio_row("duration_positive","duration_positive_n","pair_n"),ratio_row("duration_zero","duration_zero_n","pair_n"),ratio_row("duration_reversed","duration_reversed_n","pair_n")]
    if d.get("event"):
        stats += [f"COUNT(*) FILTER (WHERE {d['event']} IS NOT NULL AND {d['event_field']} IS NOT NULL AND {d['event_field']} <> 0) AS event_link_n"]
        rows += [ratio_row("with_event_id_and_field","event_link_n")]
    rows += [note_row("semantic_review_required",TOPICS[topic]["review"]),note_row("linkage_interpretation","Visit IDs are presence checks, not referential integrity or ICU overlap. Event IDs need field-concept and endpoint validation; FACT_RELATIONSHIP is an additional possible path.")]
    ctes=concept_cte(topic)+",\n"+candidate_cte(topic,table)+",\nstats AS (SELECT\n    "+",\n    ".join(stats)+"\nFROM candidate_rows)"
    emit(f"{topic}_{table}",topic,["concept",table],finish(topic+" / "+table,ctes,rows),"Candidate-row coverage, provenance, datetime, quantity/units where relevant, and linkage-field completeness. Match counts overlap and must not be summed.")

def semantic_inventory(topic,table):
    # Aggregate vocabulary-only labels. Never expose a person ID or free clinical text.
    d=DOMAINS[table]
    ctes=concept_cte(topic)+",\n"+candidate_cte(topic,table)+""",
kind_rows AS (
 SELECT DISTINCT c."""+d['id']+""" AS event_id, v.provenance, v.kind
 FROM candidate_rows c
 CROSS JOIN LATERAL (VALUES ('standard', standard_kind), ('source', source_kind), ('value', value_kind)) v(provenance,kind)
 WHERE v.kind IS NOT NULL
), counts AS (
 SELECT provenance, kind, COUNT(*) AS n FROM kind_rows GROUP BY provenance,kind
)
SELECT """+lit(topic+" / "+table+" / semantic candidates")+"""::text AS category,
       provenance || '/' || kind AS variable, n::text AS result,
       n::numeric AS numerator, NULL::numeric AS denominator
FROM counts ORDER BY provenance, kind;
"""
    emit(f"{topic}_{table}_semantic_inventory",topic,["concept",table],"WITH\n"+ctes,"Counts by candidate semantic class and standard/source/value provenance. Classes are provisional and overlapping across provenance.")

def linked_visit_check(topic,table):
    d=DOMAINS[table]
    ctes=concept_cte(topic)+",\n"+candidate_cte(topic,table)+f""",
stats AS (
 SELECT COUNT(*) AS n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL) AS linked_n,
  COUNT(*) FILTER (WHERE c.visit_occurrence_id IS NOT NULL AND v.visit_occurrence_id IS NULL) AS orphan_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id <> c.person_id) AS person_mismatch_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND v.person_id = c.person_id) AS valid_person_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.{d['dt']} IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL) AS comparable_n,
  COUNT(*) FILTER (WHERE v.visit_occurrence_id IS NOT NULL AND c.{d['dt']} IS NOT NULL AND v.visit_start_datetime IS NOT NULL AND v.visit_end_datetime IS NOT NULL AND (c.{d['dt']} < v.visit_start_datetime OR c.{d['dt']} > v.visit_end_datetime)) AS outside_n
 FROM candidate_rows c
 LEFT JOIN {{{{schema}}}}.visit_occurrence v ON v.visit_occurrence_id=c.visit_occurrence_id
)"""
    rows=[ratio_row("visit_id_resolves_same_person","valid_person_n","linked_n"),ratio_row("orphan_visit_id","orphan_n","linked_n"),ratio_row("visit_person_mismatch","person_mismatch_n","linked_n"),ratio_row("event_outside_linked_visit_datetime","outside_n","comparable_n"),note_row("semantic_review_required","Out-of-visit timestamps may reflect charting, transfers or source-time conventions. This checks start/event time only; ICU visit_detail boundaries need separate review.")]
    emit(f"{topic}_{table}_visit_validation",topic,["concept",table,"visit_occurrence"],finish(topic+" / "+table+" / visit validation",ctes,rows),"Resolve visit IDs, person identity and event/start timestamp against linked hospitalization boundaries.")

def build_basic():
    tables={
      "transfusion":["procedure_occurrence","drug_exposure","device_exposure","measurement","observation"],
      "microbiology_ast":["measurement"],
      "continuous_infusions":["measurement","observation"],
      "mechanical_ventilation":["procedure_occurrence","device_exposure","measurement","observation"],
      "code_status":["observation","condition_occurrence"],
      "fluid_balance":["measurement","observation"],
      "dialysis_rrt":["procedure_occurrence","device_exposure","measurement","observation"],
    }
    for topic,domains in tables.items():
        discovery(topic)
        for table in domains:
            generic(topic,table)
            if topic in {"transfusion","mechanical_ventilation","code_status","dialysis_rrt"}:
                semantic_inventory(topic,table)
        primary={"transfusion":"procedure_occurrence","microbiology_ast":"measurement","continuous_infusions":"measurement","mechanical_ventilation":"procedure_occurrence","code_status":"observation","fluid_balance":"measurement","dialysis_rrt":"procedure_occurrence"}[topic]
        linked_visit_check(topic,primary)

if __name__ == "__main__":
    build_basic()
    # Detailed screens are appended by build_detailed.py before manifest is saved.
    import runpy
    runpy.run_path(str(SQL/"build_detailed.py"),init_globals={"api":globals()})
    fixtures = SQL / "fixtures"
    cases = json.loads((fixtures / "dialysis_classifier_cases.json").read_text(encoding="utf-8"))
    fixture_values = ",\n    ".join("(" + lit(c["concept_name"]) + ", " + lit(c["expected_kind"]) + ")" for c in cases)
    fixture_sql = (
        "-- Synthetic vocabulary-label regression fixture; no clinical tables or patient data.\n"
        "-- Expected result: zero mismatch rows when run on PostgreSQL 12+.\n"
        "WITH cases(concept_name, expected_kind) AS (VALUES\n    " + fixture_values + "),\n"
        "classified AS (SELECT c.*, " + TOPICS["dialysis_rrt"]["kind"] + " AS actual_kind FROM cases c)\n"
        "SELECT concept_name, expected_kind, actual_kind FROM classified\n"
        "WHERE actual_kind IS DISTINCT FROM expected_kind ORDER BY concept_name;\n"
    )
    (fixtures / "dialysis_classifier_regression.sql").write_text(fixture_sql,encoding="utf-8")
    (ROOT/"config"/"manifest.json").write_text(json.dumps(MANIFEST,indent=2)+"\n",encoding="utf-8")
    print(f"Wrote {len(MANIFEST)} read-only aggregate templates")
