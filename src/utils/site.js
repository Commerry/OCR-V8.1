/*
 * Which plant this camera belongs to, as shown in its pages.
 *
 * It used to be typed straight into index.html and login.html, with an
 * "Edit" comment next to it - which meant every firmware update put STA-SK
 * back on every other site's screen. It lives in config.json now, the file
 * an update never touches:
 *
 *   "site": { "code": "STA-SK", "title": "OCR-STA-SK", "company": "STGT" }
 *
 * The OCR Center writes it when it installs a camera, and moves it out of the
 * old HTML on the first update of a camera that predates this.
 */
const DEFAULTS = { code: 'STA-SK', title: 'OCR-STA-SK', company: 'STGT' };

const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[c]));

const siteInfo = (config) => {
  const site = (config && config.site) || {};
  const pick = (key) => (typeof site[key] === 'string' && site[key].trim() ? site[key].trim() : DEFAULTS[key]);
  return { code: pick('code'), title: pick('title'), company: pick('company') };
};

/**
 * Fill {{SITE_CODE}}, {{SITE_TITLE}}, {{SITE_COMPANY}} and {{FIRMWARE_VERSION}}
 * into a page. The version shown is the one running, so a technician at the
 * camera can read it straight off the screen after an update.
 */
const applySite = (html, config, version = '') => {
  const site = siteInfo(config);
  return String(html)
    .replace(/\{\{SITE_CODE\}\}/g, escapeHtml(site.code))
    .replace(/\{\{SITE_TITLE\}\}/g, escapeHtml(site.title))
    .replace(/\{\{SITE_COMPANY\}\}/g, escapeHtml(site.company))
    .replace(/\{\{FIRMWARE_VERSION\}\}/g, escapeHtml(version));
};

export { siteInfo, applySite, DEFAULTS };
