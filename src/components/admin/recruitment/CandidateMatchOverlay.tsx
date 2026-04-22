import { useEffect, useState } from 'react';
import { X, Sparkles, Mail, Phone, Linkedin, Briefcase, RefreshCw } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Progress } from '@/components/ui/progress';
import { Button } from '@/components/ui/button';
import { useApplication, useScoreCandidate } from '@/hooks/useRecruitment';
import { cn } from '@/lib/utils';

interface Props {
  applicationId: string | null;
  onClose: () => void;
}

interface MatchBreakdown {
  skills?: number;
  experience?: number;
  education?: number;
  location?: number;
  culture_fit?: number;
}

const DIMENSIONS: Array<{ key: keyof MatchBreakdown; label: string; tone: string }> = [
  { key: 'skills', label: 'Skills', tone: '[&>div]:bg-emerald-500' },
  { key: 'experience', label: 'Experience', tone: '[&>div]:bg-blue-500' },
  { key: 'education', label: 'Education', tone: '[&>div]:bg-purple-500' },
  { key: 'location', label: 'Location', tone: '[&>div]:bg-amber-500' },
  { key: 'culture_fit', label: 'Culture fit', tone: '[&>div]:bg-pink-500' },
];

function AnimatedProgress({ value, delay = 0, className }: { value: number; delay?: number; className?: string }) {
  const [v, setV] = useState(0);
  useEffect(() => {
    const t = setTimeout(() => {
      // simple ease-out animation over ~700ms using rAF
      const start = performance.now();
      const duration = 700;
      let raf = 0;
      const tick = (now: number) => {
        const p = Math.min(1, (now - start) / duration);
        const eased = 1 - Math.pow(1 - p, 3);
        setV(Math.round(eased * value));
        if (p < 1) raf = requestAnimationFrame(tick);
      };
      raf = requestAnimationFrame(tick);
      return () => cancelAnimationFrame(raf);
    }, delay);
    return () => clearTimeout(t);
  }, [value, delay]);
  return <Progress value={v} className={className} />;
}

function recColor(rec: string | null | undefined) {
  if (rec === 'advance') return 'bg-emerald-500/15 text-emerald-700 dark:text-emerald-400 border-emerald-500/30';
  if (rec === 'hold') return 'bg-amber-500/15 text-amber-700 dark:text-amber-400 border-amber-500/30';
  if (rec === 'reject') return 'bg-rose-500/15 text-rose-700 dark:text-rose-400 border-rose-500/30';
  return 'bg-muted text-muted-foreground';
}

function recLabel(rec: string | null | undefined) {
  if (rec === 'advance') return '✓ Advance';
  if (rec === 'hold') return '⏸ Hold for review';
  if (rec === 'reject') return '✕ Likely reject';
  return 'Not yet evaluated';
}

export function CandidateMatchOverlay({ applicationId, onClose }: Props) {
  const { data, isLoading } = useApplication(applicationId ?? undefined);
  const score = useScoreCandidate();

  // ESC to close
  useEffect(() => {
    if (!applicationId) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [applicationId, onClose]);

  if (!applicationId) return null;

  return (
    <div
      className="fixed inset-0 z-50 overflow-y-auto bg-background/95 backdrop-blur-sm animate-in fade-in duration-200"
      onClick={onClose}
    >
      <div
        className="min-h-full animate-in fade-in slide-in-from-bottom-8 duration-300"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Sticky header */}
        <div className="sticky top-0 z-10 border-b border-border bg-background/95 backdrop-blur-sm">
          <div className="mx-auto flex max-w-3xl items-center justify-between gap-4 px-4 py-3">
            <div className="min-w-0">
              <h2 className="truncate text-lg font-bold">{data?.candidate_name ?? 'Loading…'}</h2>
              <p className="truncate text-sm text-muted-foreground">
                {(data as any)?.job_postings?.title ?? ''}
              </p>
            </div>
            <div className="flex items-center gap-2">
              {data?.ai_score != null && (
                <div className="rounded-full bg-primary px-3 py-1.5 text-sm font-bold text-primary-foreground">
                  {Math.round(data.ai_score)}% ✨
                </div>
              )}
              <button
                onClick={onClose}
                className="flex h-10 w-10 items-center justify-center rounded-full bg-muted hover:bg-muted/80"
                aria-label="Close"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
          </div>
        </div>

        <div className="mx-auto max-w-3xl space-y-6 px-4 py-6 pb-24">
          {isLoading || !data ? (
            <p className="text-center text-muted-foreground">Loading candidate…</p>
          ) : (
            <>
              {/* Contact */}
              <div className="flex flex-wrap items-center gap-3 text-sm text-muted-foreground">
                <span className="flex items-center gap-1.5">
                  <Mail className="h-3.5 w-3.5" /> {data.candidate_email}
                </span>
                {data.candidate_phone && (
                  <span className="flex items-center gap-1.5">
                    <Phone className="h-3.5 w-3.5" /> {data.candidate_phone}
                  </span>
                )}
                {data.linkedin_url && (
                  <a
                    href={data.linkedin_url}
                    target="_blank"
                    rel="noreferrer"
                    className="flex items-center gap-1.5 hover:text-foreground"
                  >
                    <Linkedin className="h-3.5 w-3.5" /> LinkedIn
                  </a>
                )}
                {(data as any).job_postings?.department && (
                  <span className="flex items-center gap-1.5">
                    <Briefcase className="h-3.5 w-3.5" /> {(data as any).job_postings.department}
                  </span>
                )}
              </div>

              {/* Recommendation pill */}
              {data.ai_score != null && (
                <div className="flex items-center gap-3">
                  <Badge variant="outline" className={cn('px-3 py-1.5 text-sm', recColor((data as any).recommendation))}>
                    {recLabel((data as any).recommendation)}
                  </Badge>
                  {(data as any).confidence_level && (
                    <span className="text-xs text-muted-foreground">
                      Confidence: <span className="font-semibold capitalize">{(data as any).confidence_level}</span>
                    </span>
                  )}
                </div>
              )}

              {/* Empty state */}
              {data.ai_score == null && (
                <div className="rounded-xl border border-dashed bg-muted/30 p-6 text-center">
                  <Sparkles className="mx-auto mb-2 h-8 w-8 text-muted-foreground" />
                  <p className="mb-4 text-sm text-muted-foreground">
                    This candidate hasn't been scored yet.
                  </p>
                  <Button onClick={() => score.mutate(data.id)} disabled={score.isPending}>
                    <Sparkles className="mr-2 h-4 w-4" />
                    {score.isPending ? 'Scoring…' : 'Score candidate'}
                  </Button>
                </div>
              )}

              {/* Match breakdown */}
              {data.ai_score != null && (
                <div className="space-y-4">
                  <div className="flex items-center justify-between">
                    <div>
                      <h3 className="text-xl font-bold">Match breakdown</h3>
                      <p className="text-sm text-muted-foreground">Why this candidate fits the role</p>
                    </div>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => score.mutate(data.id)}
                      disabled={score.isPending}
                    >
                      <RefreshCw className={cn('mr-2 h-3.5 w-3.5', score.isPending && 'animate-spin')} />
                      Re-score
                    </Button>
                  </div>

                  <div className="space-y-3">
                    {DIMENSIONS.map((dim, i) => {
                      const v = ((data as any).match_breakdown?.[dim.key] ?? 0) as number;
                      return (
                        <div key={dim.key} className="flex items-center gap-3">
                          <span className="w-28 text-sm font-medium text-muted-foreground">{dim.label}</span>
                          <div className="flex flex-1 items-center gap-2">
                            <AnimatedProgress value={v} delay={150 + i * 80} className={cn('h-2', dim.tone)} />
                            <span className="w-12 text-right text-sm font-semibold">{v}%</span>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}

              {/* Skills analysis */}
              {(data.matching_skills?.length || data.missing_skills?.length) ? (
                <div className="space-y-4 border-t border-border/30 pt-6">
                  <h4 className="flex items-center gap-2 text-base font-semibold">💡 Skills analysis</h4>

                  <div>
                    <div className="mb-2 flex items-center gap-1.5 text-sm font-medium text-emerald-700 dark:text-emerald-400">
                      <span>✅</span>
                      <span>Has ({data.matching_skills?.length ?? 0})</span>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      {data.matching_skills?.length ? (
                        data.matching_skills.map((s) => (
                          <Badge
                            key={s}
                            variant="secondary"
                            className="border-emerald-500/20 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
                          >
                            {s}
                          </Badge>
                        ))
                      ) : (
                        <span className="text-sm italic text-muted-foreground">No matching skills found</span>
                      )}
                    </div>
                  </div>

                  {data.missing_skills?.length ? (
                    <div>
                      <div className="mb-2 flex items-center gap-1.5 text-sm font-medium text-orange-700 dark:text-orange-400">
                        <span>📚</span>
                        <span>Missing ({data.missing_skills.length})</span>
                      </div>
                      <div className="flex flex-wrap gap-2">
                        {data.missing_skills.map((s) => (
                          <Badge
                            key={s}
                            variant="secondary"
                            className="border-orange-500/20 bg-orange-500/10 text-orange-700 dark:text-orange-300"
                          >
                            {s}
                          </Badge>
                        ))}
                      </div>
                    </div>
                  ) : null}
                </div>
              ) : null}

              {/* AI summary + reasoning */}
              {(data.ai_summary || data.ai_reasoning) && (
                <div className="space-y-3 border-t border-border/30 pt-6">
                  <h4 className="text-base font-semibold">AI evaluation</h4>
                  {data.ai_summary && <p className="text-sm leading-relaxed">{data.ai_summary}</p>}
                  {data.ai_reasoning && (
                    <p className="text-sm leading-relaxed text-muted-foreground">{data.ai_reasoning}</p>
                  )}
                </div>
              )}

              {/* Cover letter */}
              {data.cover_letter && (
                <div className="space-y-2 border-t border-border/30 pt-6">
                  <h4 className="text-base font-semibold">Cover letter</h4>
                  <p className="whitespace-pre-wrap text-sm leading-relaxed text-muted-foreground">
                    {data.cover_letter}
                  </p>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
