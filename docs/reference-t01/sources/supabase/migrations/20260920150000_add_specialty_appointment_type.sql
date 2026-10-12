-- Ejecutar y confirmar este cambio antes de usar SPECIALTY en una restricción.
alter type public.appointment_type_code add value if not exists 'SPECIALTY';
