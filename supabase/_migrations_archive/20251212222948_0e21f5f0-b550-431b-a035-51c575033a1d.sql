-- Insert SEO settings (empty placeholders)
INSERT INTO public.site_settings (key, value) VALUES (
  'seo',
  '{
    "siteTitle": "My Site",
    "titleTemplate": "%s | My Site",
    "defaultDescription": "",
    "ogImage": "",
    "twitterHandle": "",
    "googleSiteVerification": "",
    "robotsIndex": true,
    "robotsFollow": true
  }'::jsonb
) ON CONFLICT (key) DO NOTHING;

-- Insert performance settings
INSERT INTO public.site_settings (key, value) VALUES (
  'performance',
  '{
    "lazyLoadImages": true,
    "prefetchLinks": true,
    "minifyHtml": false,
    "enableServiceWorker": false,
    "imageCacheMaxAge": 31536000,
    "cacheStaticAssets": true
  }'::jsonb
) ON CONFLICT (key) DO NOTHING;