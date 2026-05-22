import type { ButtonHTMLAttributes } from 'react';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'danger';
}

const variantStyles = {
  primary: { background: '#0066cc', color: 'white' },
  secondary: { background: '#f0f0f0', color: '#333' },
  danger: { background: '#cc0000', color: 'white' },
};

export function Button({ variant = 'primary', style, children, ...rest }: ButtonProps) {
  return (
    <button
      style={{
        padding: '8px 16px',
        border: 'none',
        borderRadius: 4,
        cursor: 'pointer',
        ...variantStyles[variant],
        ...style,
      }}
      {...rest}
    >
      {children}
    </button>
  );
}
