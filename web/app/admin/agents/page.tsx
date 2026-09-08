import Shell from '@/components/shell';
import { listAgents } from '@/lib/backend';

import AgentsManager from './components/agents-manager';

export const dynamic = 'force-dynamic';

export default async function AdminAgentsPage() {
  const agents = await listAgents();

  return (
    <Shell
      title="Agent Unit Allocation"
      subtitle="Deposit or withdraw unit points on agent accounts. Movements are applied with pessimistic row locking and recorded in the immutable ledger."
      roleLabel="SUPER ADMIN"
    >
      <AgentsManager initialAgents={agents} />
    </Shell>
  );
}