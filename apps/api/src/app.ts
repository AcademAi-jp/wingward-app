import { Hono } from "hono";
import type { Env } from "./env";
import { errorHandler } from "./middleware/error";
import auth from "./routes/auth";
import quiz from "./routes/quiz";
import speedDating from "./routes/speed-dating";
import profiles from "./routes/profiles";
import personas from "./routes/personas";
import matching from "./routes/matching";
import demoJudge from "./routes/demo-judge";
import judgeCounterpart from "./routes/judge-counterpart";
import judgeReadiness from "./routes/judge-readiness";
import judgeVoiceReadiness from "./routes/judge-voice-readiness";
import recordingRehearsalMatching from "./routes/recording-rehearsal-matching";
import matches from "./routes/matches";
import internal from "./routes/internal";
import { requireInternalAuth } from "./middleware/internal-auth";
import { judgeAccessGate } from "./middleware/judge-access-gate";
import { productionE2EGate } from "./middleware/production-e2e-gate";
import foxConversations from "./routes/fox-conversations";
import partnerFoxChats from "./routes/partner-fox-chats";
import chatRequests from "./routes/chat-requests";
import directChats from "./routes/direct-chats";
import chatMeetups from "./routes/chat-meetups";
import moderation from "./routes/moderation";
import foxSearch from "./routes/fox-search";
import foxSearchWs from "./routes/fox-search-ws";
import notificationEvents from "./routes/notification-events";
import meetups from "./routes/meetups";
import meetupReflections from "./routes/meetup-reflections";
import revenuecatWebhook from "./routes/revenuecat-webhook";
import billing from "./routes/billing";
import syntheticSession from "./routes/synthetic-session";

const app = new Hono<Env>();

app.onError(errorHandler);

// This is an HTTP-only optional boundary. Keep it before every route mount;
// the scheduled handler in index.ts invokes its own service directly.
app.use("*", judgeAccessGate);
app.use("*", productionE2EGate);

app.get("/api/hello", (c) => {
	return c.json({ data: { message: "Hello Hono!" } });
});

app.route("/api/auth", auth);
app.route("/api/testing", syntheticSession);
app.route("/api/quiz", quiz);
app.route("/api/speed-dating", speedDating);
app.route("/api/profiles", profiles);
app.route("/api/personas", personas);
app.route("/api/matching", matching);
app.route("/api/demo-judge", demoJudge);
app.route("/api/judge", judgeCounterpart);
app.route("/api/judge", judgeReadiness);
app.route("/api/judge", judgeVoiceReadiness);
app.route("/api/recording-rehearsal", recordingRehearsalMatching);
app.route("/api/matches", matches);
// RevenueCat sends this public webhook directly. Keep it above the internal
// auth boundary; it has its own exact Authorization + HMAC checks.
app.route("/api/webhooks/revenuecat", revenuecatWebhook);
app.route("/api/billing", billing);
app.use("/api/internal/*", requireInternalAuth);
app.route("/api/internal", internal);
app.route("/api/fox-conversations", foxConversations);
app.route("/api/partner-fox-chats", partnerFoxChats);
app.route("/api/chat-requests", chatRequests);
app.route("/api/direct-chats", directChats);
app.route("/api/chat-meetups", chatMeetups);
app.route("/api/moderation", moderation);
app.route("/api/fox-search", foxSearch);
app.route("/api/fox-search", foxSearchWs);
app.route("/api/notification-events", notificationEvents);
app.route("/api/meetups", meetups);
app.route("/api/meetup-reflections", meetupReflections);

export type AppType = typeof app;

export { app };
