import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Mogok Maung | Management Portal',
  description:
    'Super Admin and Agent management portal for the Mogok Maung betting platform',
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}