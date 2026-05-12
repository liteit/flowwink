/**
 * Admin Smoke Test
 *
 * Runs the most common admin actions (leads, blog, KB) end-to-end through
 * `agent-execute` so we can quickly detect regressions like 401s, missing
 * skills, broken handlers, or contract drift — and report failures directly
 * in the UI instead of finding them through FlowChat.
 */

import { useState } from 'react';
import { Play, CheckCircle2, XCircle, Loader2, Clock, AlertTriangle } from 'lucide-react';
import { AdminLayout } from '@/components/admin/AdminLayout';
import { AdminPageHeader } from '@/components/admin/AdminPageHeader';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { supabase } from '@/integrations/supabase/client';

type Status = 'pending' | 'running' | 'pass' | 'fail' | 'skip';

interface StepResult {
  status: Status;
  duration_ms?: number;
  error?: string;
  output?: any;
}

interface Ctx {
  leadId?: string;
  blogPostId?: string;
  blogPostSlug?: string;
  articleId?: string;
  articleSlug?: string;
}

interface Step {
  key: string;
  group: 'leads' | 'blog' | 'kb';
  title: string;
  description: string;
  skill: string;
  args: (ctx: Ctx) => Record<string, any> | null;
  capture?: (output: any, ctx: Ctx) => void;
  /** If true, failure does not abort the suite. */
  optional?: boolean;
}

const SUFFIX = () => Math.random().toString(36).slice(2, 8);

function buildSteps(runId: string): Step[] {
  const email = `smoke+${runId}@flowwink.test`;
  const blogTitle = `Smoke Test Post ${runId}`;
  const kbSlugBase = `smoke-test-${runId}`;
  return [
    // ── Leads ────────────────────────────────────────────────────────
    {
      key: 'leads.list',
      group: 'leads',
      title: 'List leads',
      description: 'manage_leads · action=list',
      skill: 'manage_leads',
      args: () => ({ action: 'list', limit: 5 }),
    },
    {
      key: 'leads.add',
      group: 'leads',
      title: 'Add lead',
      description: 'add_lead · creates a smoke-test lead',
      skill: 'add_lead',
      args: () => ({ name: `Smoke Test ${runId}`, email, source: 'smoke-test' }),
      capture: (out, ctx) => {
        ctx.leadId = out?.lead?.id ?? out?.id ?? out?.lead_id;
      },
    },
    {
      key: 'leads.update',
      group: 'leads',
      title: 'Update lead status',
      description: 'manage_leads · action=update status=opportunity',
      skill: 'manage_leads',
      args: (ctx) => (ctx.leadId ? { action: 'update', lead_id: ctx.leadId, status: 'opportunity' } : null),
    },
    {
      key: 'leads.delete',
      group: 'leads',
      title: 'Delete lead (cleanup)',
      description: 'manage_leads · action=delete',
      skill: 'manage_leads',
      args: (ctx) => (ctx.leadId ? { action: 'delete', lead_id: ctx.leadId } : null),
    },

    // ── Blog ─────────────────────────────────────────────────────────
    {
      key: 'blog.categories',
      group: 'blog',
      title: 'List blog categories',
      description: 'manage_blog_categories · action=list',
      skill: 'manage_blog_categories',
      args: () => ({ action: 'list' }),
      optional: true,
    },
    {
      key: 'blog.draft',
      group: 'blog',
      title: 'Draft blog post',
      description: 'write_blog_post · status=draft',
      skill: 'write_blog_post',
      args: () => ({
        title: blogTitle,
        content: 'This post was created by the admin smoke test. Safe to delete.',
        status: 'draft',
      }),
      capture: (out, ctx) => {
        ctx.blogPostId = out?.post?.id ?? out?.id ?? out?.post_id;
        ctx.blogPostSlug = out?.post?.slug ?? out?.slug;
      },
    },
    {
      key: 'blog.publish',
      group: 'blog',
      title: 'Publish blog post',
      description: 'write_blog_post · status=published (single call)',
      skill: 'write_blog_post',
      args: () => ({
        title: `${blogTitle} (published)`,
        content: 'Published by the admin smoke test. Safe to delete.',
        status: 'published',
      }),
    },

    // ── Knowledge base ───────────────────────────────────────────────
    {
      key: 'kb.create',
      group: 'kb',
      title: 'Create KB article',
      description: 'manage_kb_article · action=create',
      skill: 'manage_kb_article',
      args: () => ({
        action: 'create',
        title: `Smoke Test KB ${runId}`,
        slug: kbSlugBase,
        question: 'Is the smoke test working?',
        answer: 'Yes — this article was created by the admin smoke test.',
      }),
      capture: (out, ctx) => {
        ctx.articleId = out?.article_id ?? out?.id;
        ctx.articleSlug = out?.slug ?? kbSlugBase;
      },
    },
    {
      key: 'kb.publish',
      group: 'kb',
      title: 'Publish KB article',
      description: 'manage_kb_article · action=publish (chained from create)',
      skill: 'manage_kb_article',
      args: (ctx) => {
        if (!ctx.articleId && !ctx.articleSlug) return null;
        return ctx.articleId
          ? { action: 'publish', article_id: ctx.articleId }
          : { action: 'publish', slug: ctx.articleSlug };
      },
    },
    {
      key: 'kb.unpublish',
      group: 'kb',
      title: 'Unpublish KB article (cleanup)',
      description: 'manage_kb_article · action=unpublish',
      skill: 'manage_kb_article',
      args: (ctx) =>
        ctx.articleId
          ? { action: 'unpublish', article_id: ctx.articleId }
          : ctx.articleSlug
          ? { action: 'unpublish', slug: ctx.articleSlug }
          : null,
      optional: true,
    },
  ];
}

async function callSkill(name: string, args: Record<string, any>) {
  const session = (await supabase.auth.getSession()).data.session;
  const url = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/agent-execute`;
  const headers = {
    'Content-Type': 'application/json',
    apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
    Authorization: `Bearer ${session?.access_token ?? import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}`,
  };
  const t0 = performance.now();
  const resp = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ skill_name: name, arguments: args, agent_type: 'admin-smoke-test' }),
  });
  const dt = Math.round(performance.now() - t0);
  let data: any = null;
  try {
    data = await resp.json();
  } catch {
    data = { error: `HTTP ${resp.status}` };
  }
  const ok =
    resp.ok &&
    data &&
    typeof data === 'object' &&
    (data.status === 'ok' || data.success === true || data.status === 'success');
  return {
    ok,
    duration_ms: dt,
    output: data?.output ?? data?.result ?? data,
    error: ok ? undefined : data?.error || data?.message || `