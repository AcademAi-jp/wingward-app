/**
 * Database types for WingFox.
 * Generate from live Supabase with: supabase gen types typescript --project-id <ref> > src/db/types.ts
 */
export type Json =
	| string
	| number
	| boolean
	| null
	| { [key: string]: Json | undefined }
	| Json[];

export type Database = {
	public: {
		Tables: {
			daily_match_batches: {
				Row: {
					id: string;
					batch_date: string;
					status: "pending" | "matching" | "conversations_running" | "completed" | "failed";
					total_users: number;
					users_matched: number;
					total_matches: number;
					conversations_completed: number;
					conversations_failed: number;
					error_message: string | null;
					started_at: string | null;
					completed_at: string | null;
					created_at: string;
				};
				Insert: Partial<Database["public"]["Tables"]["daily_match_batches"]["Row"]> & { batch_date: string };
				Update: Partial<Database["public"]["Tables"]["daily_match_batches"]["Row"]>;
				Relationships: [];
			};
			user_profiles: {
				Row: {
					id: string;
					auth_user_id: string;
					nickname: string;
					gender: string | null;
					birth_year: number | null;
					birth_date: string | null;
					age_verified_at: string | null;
					age_verification_method: string | null;
					language: string;
					region: string;
					/** Owner-only saved UI locale (ja or en). */
					ui_locale: string;
					/** Owner-only dating market (JP or US). */
					dating_market: string;
					/** Owner-only language for future Wing Fox conversation output. */
					conversation_language: string;
					distance_unit: string;
					gender_identity: string | null;
					gender_visibility: string;
					preferred_genders: string[];
					preference_mode: string;
					location_mode: string;
					station_id: string | null;
					coarse_area_id: string | null;
					onboarding_settings_completed_at: string | null;
					avatar_url: string | null;
					/** Server-owned canonical private Storage object path; never returned to clients. */
					avatar_storage_path: string | null;
					onboarding_status: string;
					notification_seen_at: string | null;
					/** IANA timezone name (migration 20260812100000). Basis for notification quiet hours. */
					timezone: string;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					auth_user_id: string;
					nickname: string;
					gender?: string | null;
					birth_year?: number | null;
					birth_date?: string | null;
					age_verified_at?: string | null;
					age_verification_method?: string | null;
					language?: string;
					region?: string;
					ui_locale?: string;
					dating_market?: string;
					conversation_language?: string;
					distance_unit?: string;
					gender_identity?: string | null;
					gender_visibility?: string;
					preferred_genders?: string[];
					preference_mode?: string;
					location_mode?: string;
					station_id?: string | null;
					coarse_area_id?: string | null;
					onboarding_settings_completed_at?: string | null;
					avatar_url?: string | null;
					avatar_storage_path?: string | null;
					onboarding_status?: string;
					notification_seen_at?: string | null;
					timezone?: string;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["user_profiles"]["Insert"]>;
				Relationships: [];
			};
			notification_scenarios: {
				Row: {
					scenario_id: string;
					title: string;
					trigger_description: string;
					target_action: string;
					priority: string;
					quiet_hours_exempt: boolean;
					is_enabled: boolean;
					created_at: string;
				};
				Insert: {
					scenario_id: string;
					title: string;
					trigger_description: string;
					target_action: string;
					priority: string;
					quiet_hours_exempt?: boolean;
					is_enabled?: boolean;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["notification_scenarios"]["Insert"]>;
				Relationships: [];
			};
			notifications: {
				Row: {
					id: string;
					scenario_id: string;
					user_id: string;
					match_id: string | null;
					meetup_id: string | null;
					ab_variant: string | null;
					payload: Json | null;
					onesignal_notification_id: string | null;
					scheduled_for: string | null;
					sent_at: string | null;
					delivered_at: string | null;
					opened_at: string | null;
					action_completed_at: string | null;
					suppressed_reason: string | null;
					dedup_window_start: string | null;
					created_at: string;
				};
				Insert: {
					id?: string;
					scenario_id: string;
					user_id: string;
					match_id?: string | null;
					meetup_id?: string | null;
					ab_variant?: string | null;
					payload?: Json | null;
					onesignal_notification_id?: string | null;
					scheduled_for?: string | null;
					sent_at?: string | null;
					delivered_at?: string | null;
					opened_at?: string | null;
					action_completed_at?: string | null;
					suppressed_reason?: string | null;
					dedup_window_start?: string | null;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["notifications"]["Insert"]>;
				Relationships: [];
			};
			notification_events: {
				Row: {
					id: string;
					notification_id: string;
					user_id: string;
					event_type: string;
					screen: string | null;
					occurred_at: string;
					metadata: Json | null;
					created_at: string;
				};
				Insert: {
					id?: string;
					notification_id: string;
					user_id: string;
					event_type: string;
					screen?: string | null;
					occurred_at: string;
					metadata?: Json | null;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["notification_events"]["Insert"]>;
				Relationships: [];
			};
			quiz_questions: {
				Row: {
					id: string;
					category: string;
					question_text: string;
					options: Json;
					allow_multiple: boolean;
					sort_order: number;
					created_at: string;
				};
				Insert: {
					id: string;
					category: string;
					question_text: string;
					options: Json;
					allow_multiple?: boolean;
					sort_order: number;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["quiz_questions"]["Insert"]>;
				Relationships: [];
			};
			quiz_answers: {
				Row: {
					id: string;
					user_id: string;
					question_id: string;
					selected: Json;
					created_at: string;
				};
				Insert: {
					id?: string;
					user_id: string;
					question_id: string;
					selected: Json;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["quiz_answers"]["Insert"]>;
				Relationships: [];
			};
			persona_section_definitions: {
				Row: {
					id: string;
					title: string;
					description: string;
					generation_prompt: string;
					sort_order: number;
					editable: boolean;
					applicable_persona_types: string[];
					created_at: string;
				};
				Insert: {
					id: string;
					title: string;
					description: string;
					generation_prompt: string;
					sort_order: number;
					editable?: boolean;
					applicable_persona_types?: string[];
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["persona_section_definitions"]["Insert"]>;
				Relationships: [];
			};
			personas: {
				Row: {
					id: string;
					user_id: string;
					persona_type: string;
					name: string;
					compiled_document: string;
					version: number;
					icon_url: string | null;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					user_id: string;
					persona_type: string;
					name: string;
					compiled_document: string;
					version?: number;
					icon_url?: string | null;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["personas"]["Insert"]>;
				Relationships: [];
			};
			persona_sections: {
				Row: {
					id: string;
					persona_id: string;
					section_id: string;
					content: string;
					source: string;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					persona_id: string;
					section_id: string;
					content: string;
					source?: string;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["persona_sections"]["Insert"]>;
				Relationships: [];
			};
			speed_dating_sessions: {
				Row: {
					id: string;
					user_id: string;
					persona_id: string;
					status: string;
					message_count: number;
					started_at: string;
					completed_at: string | null;
					created_at: string;
				};
				Insert: {
					id?: string;
					user_id: string;
					persona_id: string;
					status?: string;
					message_count?: number;
					started_at?: string;
					completed_at?: string | null;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["speed_dating_sessions"]["Insert"]>;
				Relationships: [];
			};
			speed_dating_messages: {
				Row: {
					id: string;
					session_id: string;
					role: string;
					content: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					session_id: string;
					role: string;
					content: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["speed_dating_messages"]["Insert"]>;
				Relationships: [];
			};
			profiles: {
				Row: {
					id: string;
					user_id: string;
					basic_info: Json;
					personality_tags: Json;
					personality_analysis: Json;
					interaction_style: Json;
					confirmed_preferences: Json;
					merged_persona_version: number;
					interests: Json;
					values: Json;
					romance_style: Json;
					communication_style: Json;
					lifestyle: Json;
					status: string;
					version: number;
					confirmed_at: string | null;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					user_id: string;
					basic_info?: Json;
					personality_tags?: Json;
					personality_analysis?: Json;
					interaction_style?: Json;
					confirmed_preferences?: Json;
					merged_persona_version?: number;
					interests?: Json;
					values?: Json;
					romance_style?: Json;
					communication_style?: Json;
					lifestyle?: Json;
					status?: string;
					version?: number;
					confirmed_at?: string | null;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["profiles"]["Insert"]>;
				Relationships: [];
			};
			daily_match_pairs: {
				Row: {
					match_id: string;
					match_date: string;
					created_at: string;
				};
				Insert: {
					match_id: string;
					match_date: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["daily_match_pairs"]["Insert"]>;
				Relationships: [];
			};
			matches: {
				Row: {
					id: string;
					user_a_id: string;
					user_b_id: string;
					profile_score: number | null;
					conversation_score: number | null;
					final_score: number | null;
					score_details: Json;
					layer_scores: Json;
					status: string;
					fox_conversation_requested_at: string | null;
					fox_conversation_requested_by: string | null;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					user_a_id: string;
					user_b_id: string;
					profile_score?: number | null;
					conversation_score?: number | null;
					final_score?: number | null;
					score_details?: Json;
					layer_scores?: Json;
					status?: string;
					fox_conversation_requested_at?: string | null;
					fox_conversation_requested_by?: string | null;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["matches"]["Insert"]>;
				Relationships: [];
			};
			meetups: {
				Row: {
					id: string;
					match_id: string;
					initiator_id: string;
					status: string;
					intent_a_at: string | null;
					intent_b_at: string | null;
					confirmed_start_at: string | null;
					confirmed_timezone: string | null;
					area: string | null;
					format: string | null;
					venue_id: string | null;
					intent_expires_at: string | null;
					proposal_expires_at: string | null;
					arrange_attempt_count: number;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					match_id: string;
					initiator_id: string;
					status?: string;
					intent_a_at?: string | null;
					intent_b_at?: string | null;
					confirmed_start_at?: string | null;
					confirmed_timezone?: string | null;
					area?: string | null;
					format?: string | null;
					venue_id?: string | null;
					intent_expires_at?: string | null;
					proposal_expires_at?: string | null;
					arrange_attempt_count?: number;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["meetups"]["Insert"]>;
				Relationships: [];
			};
			meetup_preferences: {
				Row: {
					user_id: string;
					availability: Json;
					areas: string[];
					budget_band: string | null;
					formats: string[];
					constraints: Json;
					updated_at: string;
				};
				Insert: {
					user_id: string;
					availability?: Json;
					areas?: string[];
					budget_band?: string | null;
					formats?: string[];
					constraints?: Json;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["meetup_preferences"]["Insert"]>;
				Relationships: [];
			};
			meetup_proposals: {
				Row: {
					id: string;
					meetup_id: string;
					attempt_number: number;
					candidates: Json;
					area: string | null;
					format: string | null;
					budget_band: string | null;
					rationale: string | null;
					generated_by_conversation_id: string | null;
					expires_at: string | null;
					created_at: string;
				};
				Insert: {
					id?: string;
					meetup_id: string;
					attempt_number?: number;
					candidates: Json;
					area?: string | null;
					format?: string | null;
					budget_band?: string | null;
					rationale?: string | null;
					generated_by_conversation_id?: string | null;
					expires_at?: string | null;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["meetup_proposals"]["Insert"]>;
				Relationships: [];
			};
			meetup_proposal_responses: {
				Row: {
					id: string;
					proposal_id: string;
					user_id: string;
					selected_candidate_indexes: number[] | null;
					response: string | null;
					responded_at: string;
				};
				Insert: {
					id?: string;
					proposal_id: string;
					user_id: string;
					selected_candidate_indexes?: number[] | null;
					response?: string | null;
					responded_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["meetup_proposal_responses"]["Insert"]>;
				Relationships: [];
			};
			meetup_arrangement_claims: {
				Row: {
					id: string;
					meetup_id: string;
					user_id: string;
					operation_key: string;
					is_retry: boolean;
					attempt_number: number;
					billing_source: string;
					period_start: string | null;
					created_at: string;
				};
				Insert: {
					id?: string;
					meetup_id: string;
					user_id: string;
					operation_key: string;
					is_retry: boolean;
					attempt_number: number;
					billing_source: string;
					period_start?: string | null;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["meetup_arrangement_claims"]["Insert"]>;
				Relationships: [];
			};
			interaction_dna_scores: {
				Row: {
					id: string;
					match_id: string;
					feature_id: number;
					feature_name: string;
					raw_score: number;
					normalized_score: number;
					confidence: number;
					evidence: Json;
					source_phase: string;
					computed_at: string;
				};
				Insert: {
					id?: string;
					match_id: string;
					feature_id: number;
					feature_name: string;
					raw_score: number;
					normalized_score: number;
					confidence?: number;
					evidence?: Json;
					source_phase: string;
					computed_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["interaction_dna_scores"]["Insert"]>;
				Relationships: [];
			};
			fox_conversations: {
				Row: {
					id: string;
					match_id: string;
					status: string;
					total_rounds: number;
					current_round: number;
					conversation_analysis: Json;
					started_at: string | null;
					completed_at: string | null;
					purpose: string;
					meetup_id: string | null;
					cache_hit_tokens: number | null;
					input_tokens: number | null;
					output_tokens: number | null;
					created_at: string;
				};
				Insert: {
					id?: string;
					match_id: string;
					status?: string;
					total_rounds?: number;
					current_round?: number;
					conversation_analysis?: Json;
					started_at?: string | null;
					completed_at?: string | null;
					purpose?: string;
					meetup_id?: string | null;
					cache_hit_tokens?: number | null;
					input_tokens?: number | null;
					output_tokens?: number | null;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["fox_conversations"]["Insert"]>;
				Relationships: [];
			};
			usage_counters: {
				Row: {
					id: string;
					user_id: string;
					quota_key: string;
					period_start: string;
					period_end: string;
					used_count: number;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					user_id: string;
					quota_key: string;
					period_start: string;
					period_end: string;
					used_count?: number;
					created_at?: string;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["usage_counters"]["Insert"]>;
				Relationships: [];
			};
			entitlements: {
				Row: {
					user_id: string;
					is_active: boolean;
					product_id: string | null;
					store: string | null;
					current_period_end: string | null;
					rc_app_user_id: string | null;
					last_webhook_event_at: string | null;
					last_webhook_event_id: string | null;
					updated_at: string;
				};
				Insert: {
					user_id: string;
					is_active?: boolean;
					product_id?: string | null;
					store?: string | null;
					current_period_end?: string | null;
					rc_app_user_id?: string | null;
					last_webhook_event_at?: string | null;
					last_webhook_event_id?: string | null;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["entitlements"]["Insert"]>;
				Relationships: [
					{
						foreignKeyName: "entitlements_user_id_fkey";
						columns: ["user_id"];
						isOneToOne: true;
						referencedRelation: "user_profiles";
						referencedColumns: ["id"];
					},
				];
			};
			revenuecat_webhook_events: {
				Row: {
					id: string;
					event_id: string;
					event_type: string;
					rc_app_user_id: string | null;
					user_id: string | null;
					effective_at: string;
					entitlement_is_active: boolean | null;
					product_id: string | null;
					store: string | null;
					current_period_end: string | null;
					credit_amount: number;
					processing_status: string;
					entitlement_applied: boolean;
					received_at: string;
					processed_at: string | null;
				};
				Insert: {
					id?: string;
					event_id: string;
					event_type: string;
					rc_app_user_id?: string | null;
					user_id?: string | null;
					effective_at: string;
					entitlement_is_active?: boolean | null;
					product_id?: string | null;
					store?: string | null;
					current_period_end?: string | null;
					credit_amount?: number;
					processing_status?: string;
					entitlement_applied?: boolean;
					received_at?: string;
					processed_at?: string | null;
				};
				Update: Partial<Database["public"]["Tables"]["revenuecat_webhook_events"]["Insert"]>;
				Relationships: [
					{
						foreignKeyName: "revenuecat_webhook_events_user_id_fkey";
						columns: ["user_id"];
						isOneToOne: false;
						referencedRelation: "user_profiles";
						referencedColumns: ["id"];
					},
				];
			};
			consumable_credit_balances: {
				Row: {
					user_id: string;
					balance: number;
					updated_at: string;
				};
				Insert: {
					user_id: string;
					balance?: number;
					updated_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["consumable_credit_balances"]["Insert"]>;
				Relationships: [
					{
						foreignKeyName: "consumable_credit_balances_user_id_fkey";
						columns: ["user_id"];
						isOneToOne: true;
						referencedRelation: "user_profiles";
						referencedColumns: ["id"];
					},
				];
			};
			consumable_credit_ledger: {
				Row: {
					id: string;
					user_id: string;
					delta: number;
					entry_type: string;
					reference_id: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					user_id: string;
					delta: number;
					entry_type: string;
					reference_id: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["consumable_credit_ledger"]["Insert"]>;
				Relationships: [
					{
						foreignKeyName: "consumable_credit_ledger_user_id_fkey";
						columns: ["user_id"];
						isOneToOne: false;
						referencedRelation: "user_profiles";
						referencedColumns: ["id"];
					},
				];
			};
			fox_conversation_messages: {
				Row: {
					id: string;
					conversation_id: string;
					speaker_user_id: string;
					content: string;
					round_number: number;
					created_at: string;
				};
				Insert: {
					id?: string;
					conversation_id: string;
					speaker_user_id: string;
					content: string;
					round_number: number;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["fox_conversation_messages"]["Insert"]>;
				Relationships: [];
			};
			partner_fox_chats: {
				Row: {
					id: string;
					match_id: string;
					user_id: string;
					partner_user_id: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					match_id: string;
					user_id: string;
					partner_user_id: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["partner_fox_chats"]["Insert"]>;
				Relationships: [];
			};
			partner_fox_messages: {
				Row: {
					id: string;
					chat_id: string;
					role: string;
					content: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					chat_id: string;
					role: string;
					content: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["partner_fox_messages"]["Insert"]>;
				Relationships: [];
			};
			chat_requests: {
				Row: {
					id: string;
					match_id: string;
					requester_id: string;
					responder_id: string;
					status: string;
					responded_at: string | null;
					expires_at: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					match_id: string;
					requester_id: string;
					responder_id: string;
					status?: string;
					responded_at?: string | null;
					expires_at: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["chat_requests"]["Insert"]>;
				Relationships: [];
			};
			direct_chat_rooms: {
				Row: {
					id: string;
					match_id: string;
					status: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					match_id: string;
					status?: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["direct_chat_rooms"]["Insert"]>;
				Relationships: [];
			};
			direct_chat_messages: {
				Row: {
					id: string;
					room_id: string;
					sender_id: string;
					content: string;
					is_read: boolean;
					created_at: string;
				};
				Insert: {
					id?: string;
					room_id: string;
					sender_id: string;
					content: string;
					is_read?: boolean;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["direct_chat_messages"]["Insert"]>;
				Relationships: [];
			};
			blocks: {
				Row: {
					id: string;
					blocker_id: string;
					blocked_id: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					blocker_id: string;
					blocked_id: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["blocks"]["Insert"]>;
				Relationships: [];
			};
			reports: {
				Row: {
					id: string;
					reporter_id: string;
					reported_id: string;
					reason: string;
					description: string | null;
					message_id: string | null;
					status: string;
					created_at: string;
				};
				Insert: {
					id?: string;
					reporter_id: string;
					reported_id: string;
					reason: string;
					description?: string | null;
					message_id?: string | null;
					status?: string;
					created_at?: string;
				};
				Update: Partial<Database["public"]["Tables"]["reports"]["Insert"]>;
				Relationships: [];
			};
		};
		Views: Record<string, never>;
		Functions: {
			read_sora_three_interview_profile_revision_state: {
				Args: { p_user_id: string; p_rehearsal_expires_at: string };
				Returns: Array<{ outcome: string }>;
			};
			claim_sora_three_interview_profile_revision: {
				Args: { p_user_id: string; p_rehearsal_expires_at: string };
				Returns: Array<{ outcome: string; source_profile_id: string | null; source_version: number | null; session_ids: string[] | null }>;
			};
			complete_sora_three_interview_profile_revision: {
				Args: {
					p_user_id: string;
					p_rehearsal_expires_at: string;
					p_source_profile_id: string;
					p_source_version: number;
					p_candidate: Json;
				};
				Returns: Array<{ outcome: string; target_version: number | null }>;
			};
			read_account_deletion_operation: {
				Args: { p_operation_id: string };
				Returns: Array<{
					operation_id: string;
					owner_profile_id: string;
					auth_user_id: string;
					receipt_hash: string;
					status: string;
					expires_at: string;
					delete_lease_until: string | null;
				}>;
			};
			register_account_deletion_intent: {
				Args: {
					p_operation_id: string;
					p_owner_profile_id: string;
					p_auth_user_id: string;
					p_receipt_hash: string;
				};
				Returns: Array<{ result: string; status: string | null; expires_at: string | null }>;
			};
			consume_account_deletion_status_rate_limit: {
				Args: { p_operation_id: string; p_receipt_hash: string };
				Returns: boolean;
			};
			claim_account_deletion_operation: {
				Args: {
					p_operation_id: string;
					p_owner_profile_id: string;
					p_auth_user_id: string;
					p_receipt_hash: string;
					p_claim_token: string;
				};
				Returns: Array<{ result: string; status: string | null; lease_until: string | null }>;
			};
		release_account_deletion_operation: {
				Args: { p_operation_id: string; p_receipt_hash: string; p_claim_token: string };
				Returns: boolean;
			};
			mark_account_deletion_operation_deleted: {
				Args: {
					p_operation_id: string;
					p_owner_profile_id: string;
					p_auth_user_id: string;
					p_receipt_hash: string;
				};
				Returns: boolean;
			};
			persist_direct_chat_message: {
				Args: {
					p_room_id: string;
					p_sender_id: string;
					p_idempotency_key: string;
					p_content: string;
					p_content_sha256: string;
				};
				Returns: Array<{
					room_id: string;
					sender_id: string;
					outcome: string;
					message_id: string | null;
					message_content: string | null;
					message_created_at: string | null;
				}>;
			};
			recover_direct_chat_message_send: {
				Args: {
					p_room_id: string;
					p_sender_id: string;
					p_idempotency_key: string;
					p_content_sha256: string;
				};
				Returns: Array<{
					outcome: string;
					message_id: string | null;
					message_content: string | null;
					message_created_at: string | null;
				}>;
			};
			claim_partner_fox_message_send: {
				Args: {
					p_chat_id: string;
					p_owner_id: string;
					p_idempotency_key: string;
					p_content: string;
					p_content_sha256: string;
				};
				Returns: Array<{
					outcome: string;
					user_message_id: string | null;
					user_content: string | null;
					user_created_at: string | null;
					fox_message_id: string | null;
					fox_content: string | null;
					fox_created_at: string | null;
					claim_token: string | null;
				}>;
			};
			recover_partner_fox_message_send: {
				Args: {
					p_chat_id: string;
					p_owner_id: string;
					p_idempotency_key: string;
					p_content_sha256: string;
				};
				Returns: Array<{
					outcome: string;
					user_message_id: string | null;
					user_content: string | null;
					user_created_at: string | null;
					fox_message_id: string | null;
					fox_content: string | null;
					fox_created_at: string | null;
				}>;
			};
			complete_partner_fox_message_send: {
				Args: {
					p_idempotency_key: string;
					p_claim_token: string;
					p_fox_content: string;
				};
				Returns: Array<{
					outcome: string;
					user_message_id: string | null;
					user_content: string | null;
					user_created_at: string | null;
					fox_message_id: string | null;
					fox_content: string | null;
					fox_created_at: string | null;
					claim_token: string | null;
				}>;
			};
			finish_partner_fox_message_send: {
				Args: {
					p_idempotency_key: string;
					p_claim_token: string;
					p_outcome: string;
				};
				Returns: Array<{
					outcome: string;
					user_message_id: string | null;
					user_content: string | null;
					user_created_at: string | null;
					fox_message_id: string | null;
					fox_content: string | null;
					fox_created_at: string | null;
					claim_token: string | null;
				}>;
			};
			complete_speed_dating_session: {
				Args: {
					p_session_id: string;
					p_user_id: string;
					p_transcript?: Json | null;
				};
				Returns: Array<{
					session_id: string;
					status: string;
					message_count: number;
					all_sessions_completed: boolean;
					outcome: string;
				}>;
			};
			reserve_sora_recording_interview: {
				Args: {
					p_user_id: string;
					p_persona_id: string;
					p_rehearsal_expires_at: string;
					p_admission_issued_at: string;
					p_admission_expires_at: string;
				};
				Returns: Array<{ session_id: string | null; persona_id: string | null; outcome: string }>;
			};
			issue_sora_recording_interview_token: {
				Args: {
					p_user_id: string;
					p_session_id: string;
					p_rehearsal_expires_at: string;
					p_admission_issued_at: string;
					p_admission_expires_at: string;
				};
				Returns: boolean;
			};
			complete_sora_recording_interview: {
				Args: {
					p_session_id: string;
					p_user_id: string;
					p_rehearsal_expires_at: string;
					p_admission_issued_at: string;
					p_admission_expires_at: string;
					p_transcript?: Json | null;
				};
				Returns: Array<{
					session_id: string | null;
					status: string | null;
					message_count: number | null;
					all_sessions_completed: boolean;
					outcome: string;
				}>;
			};
			// public.notification_dedup_window(timestamptz) is deliberately absent.
			// It exists only as the index expression of the dedup exclusion
			// constraint (migration 20260820100000), and its EXECUTE grant is
			// revoked from anon and authenticated, so no client and no code in
			// this repo may call it. Declaring it here would advertise an RPC
			// that exists for no caller we have.
			persist_partner_fox_greeting: {
				Args: {
					p_chat_id: string;
					p_match_id: string;
					p_user_id: string;
					p_partner_user_id: string;
					p_content: string;
				};
				Returns: Array<{
					chat_id: string;
					match_id: string;
					user_id: string;
					partner_user_id: string;
					message_id: string | null;
					message_role: string | null;
					message_content: string | null;
					message_created_at: string | null;
					outcome: string;
					match_status: string | null;
					transitioned: boolean;
				}>;
			};
			get_user_profile_id: {
				Args: Record<string, never>;
				Returns: string;
			};
			/**
			 * Atomic insert-or-increment against usage_counters, gated by p_limit.
			 * Returns the new used_count, or null when the limit was already reached
			 * (the conditional UPDATE affected zero rows). See
			 * supabase/migrations/20260812110000_consume_quota.sql.
			 */
			consume_quota: {
				Args: {
					p_user_id: string;
					p_quota_key: string;
					p_period_start: string;
					p_period_end: string;
					p_limit: number;
				};
				Returns: number | null;
			};
			/** Compensating decrement for consume_quota; see same migration. */
			refund_quota: {
				Args: {
					p_user_id: string;
					p_quota_key: string;
					p_period_start: string;
				};
				Returns: null;
			};
			apply_revenuecat_webhook_event: {
				Args: {
					p_event_id: string;
					p_event_type: string;
					p_rc_app_user_id: string | null;
					p_effective_at: string;
					p_action: string;
					p_entitlement_is_active?: boolean | null;
					p_product_id?: string | null;
					p_store?: string | null;
					p_current_period_end?: string | null;
					p_credit_amount?: number;
				};
				Returns: Array<{
					result_status: string;
					resolved_user_id: string | null;
					entitlement_was_applied: boolean;
					credit_was_granted: boolean;
				}>;
			};
			grant_consumable_credits: {
				Args: {
					p_user_id: string;
					p_reference_id: string;
					p_amount: number;
				};
				Returns: number | null;
			};
			consume_consumable_credit: {
				Args: {
					p_user_id: string;
					p_reference_id: string;
				};
				Returns: boolean;
			};
			refund_consumable_credit: {
				Args: {
					p_user_id: string;
					p_reference_id: string;
				};
				Returns: boolean;
			};
			create_or_match_meetup_intent: {
				Args: {
					p_match_id: string;
					p_user_id: string;
				};
				Returns: Array<{
					meetup_id: string | null;
					outcome: string;
					status: string | null;
					initiator_id: string | null;
					matched: boolean;
				}>;
			};
			record_meetup_proposal_response: {
				Args: {
					p_meetup_id: string;
					p_proposal_id: string;
					p_user_id: string;
					p_candidate_index: number;
				};
				Returns: Array<{
					meetup_id: string;
					proposal_id: string;
					outcome: string;
					status: string | null;
					confirmed_candidate_index: number | null;
				}>;
			};
			claim_meetup_arrangement: {
				Args: {
					p_meetup_id: string;
					p_user_id: string;
					p_is_retry: boolean;
					p_operation_key: string;
				};
				Returns: Array<{
					meetup_id: string;
					match_id: string | null;
					outcome: string;
					status: string | null;
					attempt_number: number | null;
					billing_source: string | null;
					transitioned: boolean;
				}>;
			};
			persist_meetup_proposal: {
				Args: {
					p_meetup_id: string;
					p_user_id: string;
					p_attempt_number: number;
					p_candidates: Json | null;
				};
				Returns: Array<{
					meetup_id: string;
					match_id: string;
					proposal_id: string | null;
					attempt_number: number;
					outcome: string;
					status: string;
					transitioned: boolean;
				}>;
			};
			claim_expired_meetups: {
				Args: { p_now: string };
				Returns: Array<{
					meetup_id: string;
					match_id: string;
					previous_status: string;
					status: string;
					transitioned: boolean;
				}>;
			};
			};
		Enums: Record<string, never>;
		CompositeTypes: Record<string, never>;
	};
};
