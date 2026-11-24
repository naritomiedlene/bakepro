// Supabase Edge Function: sync_user_password
// Updates a user's Supabase Auth password using the service role key.
// Permissions:
// - Caller can change their own password
// - Only admins (usuario.tipousuario == 'A') can reset someone else's password
// The request must include the caller's JWT in the Authorization header.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-max-age": "86400",
};

type Payload = {
  email: string;
  password: string;
  // Optional: when resetting someone else's password, providing the Auth UUID is preferred.
  // If omitted, the function will fall back to searching by email (may require listing users).
  targetAuthUserId?: string;
};

type DebugCtx = {
  callerEmail?: string;
  targetEmail?: string;
  isSelfChange?: boolean;
};

function escapeLikePattern(input: string) {
  // Escape Postgres LIKE wildcards. We are using `ilike()` which treats the value as a pattern.
  // If the email ever contains `%` or `_`, we must escape to avoid unintended matches.
  return input.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_");
}

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}

function isValidEmail(email: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

function errToJson(e: unknown) {
  try {
    if (e == null) return null;
    if (typeof e === "string") return { message: e };
    if (e instanceof Error) {
      return {
        name: e.name,
        message: e.message,
        stack: e.stack,
        // deno/supabase errors may carry extra fields
        ...(e as unknown as Record<string, unknown>),
      };
    }
    return e as unknown;
  } catch {
    return { message: String(e) };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  try {
    // Supabase invokes typically send lowercase `authorization`, but be tolerant.
    const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization") ?? "";
    const tokenMatch = authHeader.match(/^Bearer\s+(.+)$/i);
    const jwt = tokenMatch?.[1];
    if (!jwt) return json(401, { error: "Missing Authorization Bearer token" });

    let payload: Payload;
    try {
      payload = (await req.json()) as Payload;
    } catch {
      return json(400, { error: "Invalid JSON body" });
    }

    const email = (payload.email ?? "").trim().toLowerCase();
    const password = payload.password ?? "";

    if (!email || !isValidEmail(email)) return json(400, { error: "Invalid email" });
    if (!password || password.length < 6) return json(400, { error: "Password must be at least 6 characters" });

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return json(500, { error: "Missing required Supabase environment variables" });
    }

    // 1) Verify caller identity using anon client + caller JWT.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false },
    });

    const { data: callerUserRes, error: callerUserErr } = await callerClient.auth.getUser(jwt);
    const callerUserId = callerUserRes?.user?.id ?? "";
    const callerEmail = (callerUserRes?.user?.email ?? "").trim().toLowerCase();
    if (callerUserErr || !callerUserId) {
      return json(401, { error: "Invalid token", details: errToJson(callerUserErr) });
    }
    if (!callerEmail) return json(401, { error: "Caller email not available in token" });

    // 2) Service role client for admin operations.
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      // Important: keep persistSession false in Edge runtime.
      auth: { persistSession: false },
    });

    // Normalize target inputs.
    const targetEmail = email;
    const targetAuthUserId = (payload.targetAuthUserId ?? "").trim();

    // Fast path: if the caller is changing their *own* password, do it using the caller JWT.
    // This avoids listing users and avoids any dependency on the `usuario` table.
    const isSelfByEmail = callerEmail && callerEmail === targetEmail;
    if (isSelfByEmail) {
      const { error: updateSelfErr } = await callerClient.auth.updateUser({ password });
      if (updateSelfErr) {
        console.error("Failed to update own password", updateSelfErr);
        return json(500, { ok: false, error: "Failed to update password", details: errToJson(updateSelfErr) });
      }
      return json(200, { ok: true, mode: "self" });
    }

    // From this point onward it's a "reset other user's password" scenario.
    // Only admins (usuario.tipousuario == 'A') can reset someone else's password.
    const debugCtx: DebugCtx = { callerEmail, targetEmail, isSelfChange: false };

    // Verify caller admin role via the `usuario` table, using service role (bypass RLS).
    // Keep this query minimal to avoid brittle coupling to DB column names.
    // We intentionally avoid `single()` so duplicated emails do not hard-fail.
    const { data: rows, error: callerUsuarioErr } = await adminClient
      .from("usuario")
      .select("tipousuario, email")
      // Use `eq` for exact match; case-normalize both sides.
      .eq("email", callerEmail)
      .limit(5);

    if (callerUsuarioErr) {
      console.error("Failed to verify caller permissions", callerUsuarioErr);
      // This is an internal/server-side error (schema/permissions), not a client forbidden.
      return json(500, {
        ok: false,
        error: "Permission lookup failed",
        details: errToJson(callerUsuarioErr),
        debug: debugCtx,
      });
    }

    const tipousuario = (rows?.[0]?.tipousuario ?? "") as string;
    const isAdmin = tipousuario === "A";
    if (!isAdmin) return json(403, { ok: false, error: "Only admins can reset passwords", debug: debugCtx });

    // Determine the target Auth user id.
    let resolvedTargetAuthUserId = targetAuthUserId;
    if (!resolvedTargetAuthUserId) {
      const { data: listRes, error: listErr } = await adminClient.auth.admin.listUsers({ perPage: 1000 });
      if (listErr) {
        console.error("Failed to list Auth users", listErr);
        return json(500, { ok: false, error: "Failed to list users", details: errToJson(listErr) });
      }

      const match = listRes.users.find((u) => (u.email ?? "").trim().toLowerCase() === targetEmail);
      if (!match) return json(404, { ok: false, error: "User not found in Auth" });
      resolvedTargetAuthUserId = match.id;
    }

    const { error: updateErr } = await adminClient.auth.admin.updateUserById(resolvedTargetAuthUserId, { password });
    if (updateErr) {
      console.error("Failed to update password", updateErr);
      return json(500, { ok: false, error: "Failed to update password", details: errToJson(updateErr) });
    }

    return json(200, { ok: true, mode: "admin_reset" });
  } catch (e) {
    console.error("Unexpected error", e);
    return json(500, { ok: false, error: "Unexpected error", details: errToJson(e) });
  }
});
