import { defineModule } from '@/lib/module-def';
import { z } from 'zod';

const inputSchema = z.object({
  action: z.enum(['get_config']),
});

const outputSchema = z.object({
  success: z.boolean(),
  error: z.string().optional(),
});

type Input = z.infer<typeof inputSchema>;
type Output = z.infer<typeof outputSchema>;

/**
 * Workspace Chat — internal RAG/CAG chat for admins & employees.
 *
 * - Authenticated, read-only chat against your own FlowWink data:
 *   documents, contracts, KB, pages, CRM, employees.
 * - Uses the same AI provider as the public AI Chat (Integrations).
 * - Independent of FlowPilot — works as long as an AI provider is configured.
 * - Exposes NO skills (no MCP, no mutations).
 */
export const workspaceChatModule = defineModule<Input, Output>({
  id: 'workspaceChat',
  name: 'Workspace Chat',
  version: '1.0.0',
  description:
    'Internal authenticated chat that answers questions about your documents, contracts, KB, CRM and HR data — with source citations. No mutations.',
  capabilities: ['data:read'],
  inputSchema,
  outputSchema,

  skills: [],

  async publish(_input: Input): Promise<Output> {
    return { success: true };
  },
});
