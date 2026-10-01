-- Add interaction_style column to profiles for psychological interaction data from speed dating
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS interaction_style jsonb NOT NULL DEFAULT '{}';
