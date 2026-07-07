import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { ChevronLeft, ChevronRight, Plus, Trash2, UserPlus } from "lucide-react";
import { toast } from "sonner";
import { format, addDays, startOfWeek } from "date-fns";
import { useEmployees } from "@/hooks/useEmployees";
import { useHrQuery, useHrMutation } from "@/hooks/useHrOps";

type Shift = { id: string; date: string; start: string; end: string; role: string | null; location: string | null; status: string };
type Row = { employee_id: string; employee: string; total_hours: number; shifts: Shift[] };
type OpenShift = { id: string; date: string; start: string; end: string; role: string | null; location: string | null };
type Roster = { roster: Row[]; open_shifts: OpenShift[] };

function mondayOf(d: Date) {
  return startOfWeek(d, { weekStartsOn: 1 });
}
const ymd = (d: Date) => format(d, "yyyy-MM-dd");

export function ShiftsPanel() {
  const { data: employees } = useEmployees();
  const [weekStart, setWeekStart] = useState<Date>(mondayOf(new Date()));
  const weekStartStr = ymd(weekStart);

  const rosterQ = useHrQuery<Roster>("manage_shift", { p_action: "roster", p_week_start: weekStartStr }, ["roster", weekStartStr]);
  const invalidate: string[][] = [["manage_shift", "roster", weekStartStr]];
  const assignMut = useHrMutation("manage_shift", invalidate);
  const createMut = useHrMutation("manage_shift", invalidate);
  const deleteMut = useHrMutation("manage_shift", invalidate);

  const days = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)), [weekStart]);

  const [assignTarget, setAssignTarget] = useState<OpenShift | null>(null);
  const [assignEmployee, setAssignEmployee] = useState("");
  const doAssign = async () => {
    if (!assignTarget) return;
    try {
      await assignMut.mutateAsync({ p_action: "assign", p_shift_id: assignTarget.id, p_employee_id: assignEmployee });
      toast.success("Assigned");
      setAssignTarget(null);
      setAssignEmployee("");
    } catch (err) {
      // useHrMutation already toasts the overlap message; nothing else to do
      void err;
    }
  };

  const [newOpen, setNewOpen] = useState(false);
  const [form, setForm] = useState({
    employee_id: "",
    shift_date: ymd(weekStart),
    start_time: "09:00",
    end_time: "17:00",
    role: "",
    location: "",
    break_minutes: "",
  });
  const submitNew = async () => {
    try {
      await createMut.mutateAsync({
        p_action: "create",
        p_employee_id: form.employee_id || null,
        p_shift_date: form.shift_date,
        p_start_time: form.start_time,
        p_end_time: form.end_time,
        p_role: form.role || null,
        p_location: form.location || null,
        p_break_minutes: form.break_minutes ? Number(form.break_minutes) : null,
      });
      toast.success("Shift created");
      setNewOpen(false);
    } catch { /* handled */ }
  };

  const delShift = async (id: string) => {
    if (!confirm("Delete this shift?")) return;
    try {
      await deleteMut.mutateAsync({ p_action: "delete", p_shift_id: id });
      toast.success("Deleted");
    } catch { /* handled */ }
  };

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <div className="flex items-center gap-2">
            <Button size="icon" variant="outline" className="h-8 w-8" onClick={() => setWeekStart(addDays(weekStart, -7))}>
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <CardTitle className="text-base">Week of {format(weekStart, "MMM d, yyyy")}</CardTitle>
            <Button size="icon" variant="outline" className="h-8 w-8" onClick={() => setWeekStart(addDays(weekStart, 7))}>
              <ChevronRight className="h-4 w-4" />
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setWeekStart(mondayOf(new Date()))}>Today</Button>
          </div>
          <Dialog open={newOpen} onOpenChange={setNewOpen}>
            <DialogTrigger asChild>
              <Button size="sm"><Plus className="h-4 w-4 mr-2" /> New shift</Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader><DialogTitle>New shift</DialogTitle></DialogHeader>
              <div className="grid grid-cols-2 gap-3">
                <div className="col-span-2">
                  <Label>Employee (leave empty for open shift)</Label>
                  <Select value={form.employee_id || "__open"} onValueChange={(v) => setForm({ ...form, employee_id: v === "__open" ? "" : v })}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="__open">— Open shift —</SelectItem>
                      {employees?.map((e) => <SelectItem key={e.id} value={e.id}>{e.name}</SelectItem>)}
                    </SelectContent>
                  </Select>
                </div>
                <div><Label>Date</Label><Input type="date" value={form.shift_date} onChange={(e) => setForm({ ...form, shift_date: e.target.value })} /></div>
                <div><Label>Break (min)</Label><Input type="number" value={form.break_minutes} onChange={(e) => setForm({ ...form, break_minutes: e.target.value })} /></div>
                <div><Label>Start</Label><Input type="time" value={form.start_time} onChange={(e) => setForm({ ...form, start_time: e.target.value })} /></div>
                <div><Label>End</Label><Input type="time" value={form.end_time} onChange={(e) => setForm({ ...form, end_time: e.target.value })} /></div>
                <div><Label>Role</Label><Input value={form.role} onChange={(e) => setForm({ ...form, role: e.target.value })} /></div>
                <div><Label>Location</Label><Input value={form.location} onChange={(e) => setForm({ ...form, location: e.target.value })} /></div>
              </div>
              <DialogFooter>
                <Button onClick={submitNew} disabled={createMut.isPending}>Create</Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </CardHeader>
        <CardContent>
          {rosterQ.isLoading ? <Skeleton className="h-48 w-full" /> : (
            <div className="overflow-x-auto">
              <div className="min-w-[900px] grid grid-cols-[180px_repeat(7,1fr)_80px] gap-1 text-xs">
                <div className="font-medium p-2">Employee</div>
                {days.map((d) => (
                  <div key={d.toISOString()} className="font-medium p-2 text-center border-l border-border">
                    {format(d, "EEE d")}
                  </div>
                ))}
                <div className="font-medium p-2 text-right">Hours</div>

                {!rosterQ.data?.roster.length ? (
                  <div className="col-span-9 text-center text-muted-foreground py-6">No shifts this week.</div>
                ) : rosterQ.data.roster.map((row) => (
                  <div key={row.employee_id} className="contents">
                    <div className="p-2 border-t border-border font-medium truncate">{row.employee}</div>
                    {days.map((d) => {
                      const dstr = ymd(d);
                      const dayShifts = row.shifts.filter((s) => s.date === dstr);
                      return (
                        <div key={dstr} className="p-1 border-t border-l border-border min-h-[54px] space-y-1">
                          {dayShifts.map((s) => (
                            <div key={s.id} className="group bg-primary/10 text-primary rounded px-1.5 py-1 flex items-center justify-between gap-1">
                              <span className="truncate">
                                {s.start.slice(0, 5)}–{s.end.slice(0, 5)}
                                {s.role && <span className="text-muted-foreground ml-1">· {s.role}</span>}
                              </span>
                              <button
                                onClick={() => delShift(s.id)}
                                className="opacity-0 group-hover:opacity-100 text-destructive"
                                aria-label="Delete shift"
                              >
                                <Trash2 className="h-3 w-3" />
                              </button>
                            </div>
                          ))}
                        </div>
                      );
                    })}
                    <div className="p-2 border-t border-border text-right tabular-nums">{row.total_hours.toFixed(1)}</div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle className="text-base">Open shifts</CardTitle></CardHeader>
        <CardContent>
          {rosterQ.isLoading ? <Skeleton className="h-16 w-full" /> : !rosterQ.data?.open_shifts.length ? (
            <p className="text-sm text-muted-foreground">No open shifts.</p>
          ) : (
            <div className="space-y-2">
              {rosterQ.data.open_shifts.map((s) => (
                <div key={s.id} className="flex items-center justify-between border border-border rounded p-2">
                  <div className="text-sm">
                    <span className="font-medium">{format(new Date(s.date), "EEE MMM d")}</span>{" "}
                    <span>{s.start.slice(0, 5)}–{s.end.slice(0, 5)}</span>
                    {s.role && <Badge variant="outline" className="ml-2">{s.role}</Badge>}
                    {s.location && <span className="text-muted-foreground ml-2">· {s.location}</span>}
                  </div>
                  <Button size="sm" variant="outline" onClick={() => { setAssignTarget(s); setAssignEmployee(""); }}>
                    <UserPlus className="h-3.5 w-3.5 mr-1" /> Assign
                  </Button>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <Dialog open={!!assignTarget} onOpenChange={(v) => { if (!v) setAssignTarget(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Assign open shift</DialogTitle></DialogHeader>
          <div className="space-y-3">
            {assignTarget && (
              <p className="text-sm text-muted-foreground">
                {format(new Date(assignTarget.date), "EEE MMM d")} · {assignTarget.start.slice(0, 5)}–{assignTarget.end.slice(0, 5)}
              </p>
            )}
            <Select value={assignEmployee} onValueChange={setAssignEmployee}>
              <SelectTrigger><SelectValue placeholder="Select employee" /></SelectTrigger>
              <SelectContent>
                {employees?.map((e) => <SelectItem key={e.id} value={e.id}>{e.name}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <DialogFooter>
            <Button onClick={doAssign} disabled={!assignEmployee || assignMut.isPending}>Assign</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
