-- Synthetic vocabulary-label regression fixture; no clinical tables or patient data.
-- Expected result: zero mismatch rows when run on PostgreSQL 12+.
WITH cases(concept_name, expected_kind) AS (VALUES
    ('Hemodialysis procedure with single evaluation by a physician or other qualified health care professional', 'other_rrt_candidate'),
    ('Hemodialysis procedure requiring repeated evaluations by a physician or other qualified health care professional', 'other_rrt_candidate'),
    ('Hemodialysis procedure performed by a qualified HEALTH CARE PROFESSIONAL', 'other_rrt_candidate'),
    ('Continuous renal replacement therapy performed by a qualified health-care professional', 'continuous_rrt_candidate'),
    ('Peritoneal dialysis performed by qualified healthcare professionals', 'peritoneal_dialysis_candidate'),
    ('Hemodialysis procedure performed by a health care provider', 'other_rrt_candidate'),
    ('Hemodialysis procedure performed by a health care practitioner', 'other_rrt_candidate'),
    ('Hemodialysis care', 'documentation_or_monitoring_candidate'),
    ('Dialysis care provided by a qualified health care professional', 'documentation_or_monitoring_candidate'),
    ('Dialysis care provided by a qualified health-care professional', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis aftercare', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis comments', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis pre-treatment assessment', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis reassessment', 'documentation_or_monitoring_candidate'),
    ('Monitoring of continuous renal replacement therapy', 'documentation_or_monitoring_candidate'),
    ('History of hemodialysis recorded by a qualified health care professional', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis status', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis clearance', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis blood flow', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis pressure', 'documentation_or_monitoring_candidate'),
    ('Hemodialysis catheter care', 'access_candidate'),
    ('Preoperative hemodialysis vessel assessment', 'access_candidate'),
    ('Dialysis arteriovenous fistula', 'access_candidate'),
    ('Target ultrafiltration fluid removal', 'target_removal_candidate'),
    ('Hemodialysis fluid removed', 'actual_removal_candidate')),
classified AS (SELECT c.*, CASE WHEN c.concept_name ~* 'target|prescri|desired|to.{0,3}be.{0,3}removed' THEN 'target_removal_candidate'
    WHEN c.concept_name ~* 'removed|fluid.{0,10}output|ultrafiltrat.{0,15}remov' THEN 'actual_removal_candidate'
    WHEN c.concept_name ~* 'catheter|access|fistula|preoperative' THEN 'access_candidate'
    WHEN REGEXP_REPLACE(c.concept_name, '(^|[^a-z])health[[:space:]-]*care[[:space:]-]+(professionals?|providers?|practitioners?)([^a-z]|$)', ' ', 'gi')
         ~* '(^|[^a-z])(comments?|(?:re)?assess(?:ment|ments|ed|ing)?|monitor(?:ing|ed|s)?|care|aftercare|history|status|clearance|flow|pressure)([^a-z]|$)' THEN 'documentation_or_monitoring_candidate'
    WHEN c.concept_name ~* 'continuous|crrt|ckrt|cvvh' THEN 'continuous_rrt_candidate'
    WHEN c.concept_name ~* 'peritoneal' THEN 'peritoneal_dialysis_candidate'
    ELSE 'other_rrt_candidate' END AS actual_kind FROM cases c)
SELECT concept_name, expected_kind, actual_kind FROM classified
WHERE actual_kind IS DISTINCT FROM expected_kind ORDER BY concept_name;
