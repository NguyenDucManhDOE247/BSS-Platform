import { Link } from 'react-router-dom';

export default function HomePage() {
  return (
    <section>
      <h1>Welcome to BSS Portal</h1>
      <p>Quản lý gói cước, đơn đăng ký và hóa đơn của bạn.</p>
      <ul>
        <li><Link to="/plans">Khám phá các gói cước</Link></li>
        <li><Link to="/bills">Xem hóa đơn</Link></li>
      </ul>
    </section>
  );
}
