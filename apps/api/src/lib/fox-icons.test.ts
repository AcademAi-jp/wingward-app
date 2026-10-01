import {describe,expect,it} from "vitest";
import {FOX_ICONS,WARD_ICON_URL,getRandomIconUrlForGender} from "./fox-icons";
describe("Ward API avatar presentation",()=>{
 it.each(["male","female","other","MALE","", "nonbinary"])("returns the public WingWard mark for %s",gender=>expect(getRandomIconUrlForGender(gender)).toBe("/wingward-mark.svg"));
 it("keeps legacy export shape without mascot assets",()=>{expect(FOX_ICONS).toEqual({male:[WARD_ICON_URL],female:[WARD_ICON_URL]});expect(Object.values(FOX_ICONS).flat().every(path=>!path.includes("fox"))).toBe(true);});
});
