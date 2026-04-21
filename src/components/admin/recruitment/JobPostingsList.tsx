import { Link } from 'react-router-dom';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useJobPostings } from '@/hooks/useRecruitment';
import { useToast } from '@/hooks/use-toast';
import { Briefcase, Share2, ExternalLink } from 'lucide-react';
import { NewJobDialog } from './NewJobDialog';
import { formatDistanceToNow } from 'date-fns';

const STATUS_VARIANT: Record<string, 'default' | 'secondary' | 'outline'> = {
  draft: 'outline',
  published: 'default',
  closed: 'secondary',
};

export function JobPostingsList() {
  const { data, isLoading } = useJobPostings();
  const { toast } = useToast();

  const copyShareLink = (slug: string) => {
    const url = `${window.location.origin}/jobs/${slug}`;
    navigator.clipboard.writeText(url);
    toast({ title: 'Link copied', description: url });
  };

  if (isLoading) {
    return (
      <div className="space-y-2">
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
      </div>
    );
  }

  if (!data?.length) {
    return (
      <Card>
        <CardContent className="flex flex-col items-center justify-center py-12 text-center">
          <Briefcase className="mb-4 h-12 w-12 text-muted-foreground" />
          <h3 className="mb-2 text-lg font-semibold">No open roles yet</h3>
          <p className="mb-4 text-sm text-muted-foreground">
            Create your first job posting to start collecting applications.
          </p>
          <NewJobDialog />
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Title</TableHead>
            <TableHead>Department</TableHead>
            <TableHead>Location</TableHead>
            <TableHead>Status</TableHead>
            <TableHead>Created</TableHead>
            <TableHead className="text-right">Actions</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {data.map((job) => (
            <TableRow key={job.id}>
              <TableCell className="font-medium">{job.title}</TableCell>
              <TableCell className="text-muted-foreground">{job.department ?? '—'}</TableCell>
              <TableCell className="text-muted-foreground">{job.location ?? '—'}</TableCell>
              <TableCell>
                <Badge variant={STATUS_VARIANT[job.status] ?? 'outline'}>{job.status}</Badge>
              </TableCell>
              <TableCell className="text-muted-foreground">
                {formatDistanceToNow(new Date(job.created_at), { addSuffix: true })}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex justify-end gap-1">
                  {job.status === 'published' && (
                    <>
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => copyShareLink(job.slug)}
                        title="Copy share link"
                      >
                        <Share2 className="h-4 w-4" />
                      </Button>
                      <Button asChild size="sm" variant="ghost" title="View public page">
                        <a href={`/jobs/${job.slug}`} target="_blank" rel="noreferrer">
                          <ExternalLink className="h-4 w-4" />
                        </a>
                      </Button>
                    </>
                  )}
                  <Button asChild size="sm" variant="ghost">
                    <Link to={`/admin/recruitment/jobs/${job.id}`}>Open</Link>
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </Card>
  );
}
