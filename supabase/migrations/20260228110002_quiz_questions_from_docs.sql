-- Replace quiz with 10 questions from docs/requirements/08-US-2.md (single choice, 4 options each)
-- Existing answers are removed because question IDs change.

DELETE FROM public.quiz_answers;
DELETE FROM public.quiz_questions;

INSERT INTO public.quiz_questions (id, category, question_text, options, allow_multiple, sort_order) VALUES
('q1', 'lifestyle', '', '[]'::jsonb, false, 1),
('q2', 'communication', '', '[]'::jsonb, false, 2),
('q3', 'humor', '', '[]'::jsonb, false, 3),
('q4', 'expression', '', '[]'::jsonb, false, 4),
('q5', 'values', '', '[]'::jsonb, false, 5),
('q6', 'planning', '', '[]'::jsonb, false, 6),
('q7', 'relationship', '', '[]'::jsonb, false, 7),
('q8', 'recovery', '', '[]'::jsonb, false, 8),
('q9', 'daily_rhythm', '', '[]'::jsonb, false, 9),
('q10', 'lifestyle_zone', '', '[]'::jsonb, false, 10);
