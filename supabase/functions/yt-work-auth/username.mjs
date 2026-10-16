// Employee and Cashier usernames are owner-defined labels; login is case-insensitive.
export function workUsername(value, allowCustom = false) {
  const username = String(value ?? '').trim().toLowerCase();
  if (allowCustom) {
    if (!username || Array.from(username).length > 40 || /[\u0000-\u001f\u007f]/u.test(username)) {
      throw new Error('invalid_work_username');
    }
    return username;
  }
  if (!/^[a-z][a-z0-9_]{2,23}$/.test(username)) {
    throw new Error('invalid_username');
  }
  return username;
}
