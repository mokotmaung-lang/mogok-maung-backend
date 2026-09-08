import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';

export default function HomePage() {
  const role = cookies().get('mm_role')?.value;

  if (role === 'SUPER_ADMIN') redirect('/admin/fixtures');
  if (role === 'AGENT') redirect('/agent/downline');
  redirect('/login');
}