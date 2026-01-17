import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { createBrowserRouter, RouterProvider } from 'react-router-dom';
import './index.css';
import MainPage from './components/MainPage';
import NewSessionPage from './components/NewSessionPage';
import PairingPage from './components/PairingPage';

const router = createBrowserRouter([
  {
    path: '/',
    element: <MainPage />,
  },
  {
    path: '/new',
    element: <NewSessionPage />,
  },
  {
    path: '/pair',
    element: <PairingPage />,
  },
]);

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>
);
