import Shell from '@/components/shell';
import { listFixtures } from '@/lib/backend';

import FixturesTable from './components/fixtures-table';
import SyncOddsButton from './components/sync-odds-button';

export const dynamic = 'force-dynamic';

export default async function AdminFixturesPage() {
  const fixtures = await listFixtures();

  return (
    <Shell
      title="Fixture & Odds Control"
      subtitle="Enable/disable matches and adjust Myanmar odds (+25, -36) for mobile app users."
      roleLabel="SUPER ADMIN"
      actions={<SyncOddsButton />}
    >
      <FixturesTable initialFixtures={fixtures} />
    </Shell>
  );
}