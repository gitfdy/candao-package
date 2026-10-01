export async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
  const area = document.createElement('textarea');
  const previous = document.activeElement;
  area.value = text; area.style.position = 'fixed'; area.style.opacity = '0';
  document.body.append(area);
  try { area.select(); if (!document.execCommand('copy')) throw new Error('无法自动复制，请选中地址手动复制。'); }
  finally { area.remove(); previous?.focus(); }
}
