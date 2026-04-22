import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  try {
    const { application_id } = await req.json();
    if (!application_id) {
      return new Response(JSON.stringify({ success: false, error: 'application_id required' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: app, error: appErr } = await supabase
      .from('applications')
      .select('*, job_postings(*)')
      .eq('id', application_id)
      .single();

    if (appErr || !app) {
      return new Response(JSON.stringify({ success: false, error: 'Application not found' }), {
        status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const job = (app as any).job_postings;
    if (!job) {
      return new Response(JSON.stringify({ success: false, error: 'Job posting not found' }), {
        status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');
    if (!GEMINI_API_KEY) {
      return new Response(JSON.stringify({ success: false, error: 'AI not configured' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const parsed = (app as any).parsed_resume ?? {};
    const candidateContext = JSON.stringify({
      name: app.candidate_name,
      email: app.candidate_email,
      cover_letter: app.cover_letter,
      parsed_resume: parsed,
    }, null, 2);

    const jobContext = JSON.stringify({
      title: job.title,
      department: job.department,
      location: job.location,
      employment_type: job.employment_type,
      description: job.description,
      requirements: job.requirements,
    }, null, 2);

    const systemPrompt = `You are an expert technical recruiter. Score a candidate against a job posting.

Return ONLY valid JSON:
{
  "ai_score": 75,
  "ai_reasoning": "1-3 sentences explaining the score",
  "ai_summary": "One paragraph summary of fit",
  "matching_skills": ["skill1", "skill2"],
  "missing_skills": ["skill3"],
  "match_breakdown": {
    "skills": 80,
    "experience": 70,
    "education": 60,
    "location": 90,
    "culture_fit": 75
  },
  "recommendation": "advance",
  "confidence_level": "high"
}

Each match_breakdown dimension is 0-100:
- skills: how many required skills the candidate has
- experience: years and relevance of work history vs role seniority
- education: degree level and field relevance (use 50 if not a strict requirement)
- location: geographic fit (remote roles always 100; otherwise based on location/relocation signals)
- culture_fit: tone of cover letter and signals of motivation, communication, soft skills

ai_score MUST be a weighted average roughly: skills*0.40 + experience*0.30 + education*0.10 + location*0.10 + culture_fit*0.10

recommendation:
- "advance" when ai_score >= 75
- "hold" when 55 <= ai_score < 75
- "reject" when ai_score < 55

confidence_level: "high" when resume has clear evidence for all dimensions, "medium" when some dimensions are inferred, "low" when key data is missing.

Be honest and specific. Cite actual evidence from the resume.`;

    const userPrompt = `## Job Posting\n${jobContext}\n\n## Candidate\n${candidateContext}`;

    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: `${systemPrompt}\n\n${userPrompt}` }] }],
          generationConfig: {
            temperature: 0.2,
            maxOutputTokens: 2048,
            responseMimeType: 'application/json',
          },
        }),
      }
    );

    if (!response.ok) {
      const errText = await response.text();
      console.error('Gemini error:', errText);
      return new Response(JSON.stringify({ success: false, error: 'AI scoring failed' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const result = await response.json();
    const text = result.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!text) {
      return new Response(JSON.stringify({ success: false, error: 'Empty AI response' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const cleaned = text.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
    const scoring = JSON.parse(cleaned);

    const { error: updateErr } = await supabase
      .from('applications')
      .update({
        ai_score: scoring.ai_score,
        ai_reasoning: scoring.ai_reasoning,
        ai_summary: scoring.ai_summary,
        matching_skills: scoring.matching_skills ?? [],
        missing_skills: scoring.missing_skills ?? [],
        match_breakdown: scoring.match_breakdown ?? {},
        recommendation: scoring.recommendation ?? null,
        confidence_level: scoring.confidence_level ?? null,
      })
      .eq('id', application_id);

    if (updateErr) {
      console.error('Update error:', updateErr);
      return new Response(JSON.stringify({ success: false, error: updateErr.message }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ success: true, scoring }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('score-candidate error:', error);
    return new Response(JSON.stringify({ success: false, error: (error as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
