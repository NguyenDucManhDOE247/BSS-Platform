import type { PropsWithChildren } from 'react';

interface CardProps {
  title?: string;
}

export function Card({ title, children }: PropsWithChildren<CardProps>) {
  return (
    <div style={{ border: '1px solid #e0e0e0', borderRadius: 8, padding: 16 }}>
      {title && <h3 style={{ marginTop: 0 }}>{title}</h3>}
      {children}
    </div>
  );
}
