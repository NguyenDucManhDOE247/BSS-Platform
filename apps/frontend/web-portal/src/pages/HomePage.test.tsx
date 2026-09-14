import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it } from 'vitest';
import HomePage from './HomePage';

describe('HomePage', () => {
  it('renders the welcome heading and links to plans and bills', () => {
    render(
      <MemoryRouter>
        <HomePage />
      </MemoryRouter>,
    );

    // Plain DOM assertions (no @testing-library/jest-dom matchers) — keeps devDependencies
    // minimal; getByRole already throws if the element isn't found, so reaching these lines
    // proves the heading/links exist.
    expect(screen.getByRole('heading', { name: /welcome to bss portal/i })).toBeDefined();
    expect(screen.getByRole('link', { name: /khám phá các gói cước/i }).getAttribute('href')).toBe('/plans');
    expect(screen.getByRole('link', { name: /xem hóa đơn/i }).getAttribute('href')).toBe('/bills');
  });
});
