import { publicLinks } from "../../config/publicLinks.js";
const links = publicLinks({
  macPath: import.meta.env.VITE_AIM_MAC_DOWNLOAD_PATH,
  macSha256: import.meta.env.VITE_AIM_MAC_DOWNLOAD_SHA256,
  releaseApproved: import.meta.env.VITE_AIM_PUBLIC_RELEASE_APPROVED,
  supportUrl: import.meta.env.VITE_AIM_SUPPORT_URL,
  sourceUrl: import.meta.env.VITE_AIM_SOURCE_URL,
});
export const releaseLinks = {
  macDownload: links.macDownload,
  iphone: links.iphone,
};
export const supportUrl = links.supportUrl;
export const sourceUrl = links.sourceUrl;
