import Shell from '@/components/shell';
import { listDownlines } from '@/lib/backend';

import DownlineTable from './components/downline-table';

export const dynamic = 'force-dynamic';

export default async function AgentDownlinePage() {
  const downlines = await listDownlines();

  return (
    <Shell
      title="Downline & User Management"
      subtitle="Provision new user accounts and monitor their balances."
      roleLabel="AGENT"
    >
      <DownlineTable initialDownlines={downlines} />
    </Shell>
  );
}