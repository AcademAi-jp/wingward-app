-- Quiz questions: use category keys for i18n (display labels come from frontend)
UPDATE public.quiz_questions SET category = 'personality' WHERE id IN ('q1_weekend', 'q2_travel');
UPDATE public.quiz_questions SET category = 'communication' WHERE id = 'q3_contact';
UPDATE public.quiz_questions SET category = 'hobbies' WHERE id IN ('q4_indoor', 'q5_outdoor');
UPDATE public.quiz_questions SET category = 'values' WHERE id IN ('q6_work_life', 'q7_future');
UPDATE public.quiz_questions SET category = 'romance' WHERE id IN ('q8_relationship', 'q9_partner');
UPDATE public.quiz_questions SET category = 'lifestyle' WHERE id = 'q10_diet';
UPDATE public.quiz_questions SET category = 'basic' WHERE id IN ('q11_age', 'q12_location');
