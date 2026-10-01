const ISO_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const MIN_BIRTH_DATE = "1900-01-01";

function isLeapYear(year: number): boolean {
	return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function formatUtcDate(date: Date): string {
	return `${date.getUTCFullYear().toString().padStart(4, "0")}-${(date.getUTCMonth() + 1)
		.toString()
		.padStart(2, "0")}-${date.getUTCDate().toString().padStart(2, "0")}`;
}

export function getUtcToday(now = new Date()): string {
	return formatUtcDate(now);
}

/**
 * Accepts only a real Gregorian calendar date in the supported range. The
 * returned value is the validated canonical input, not a timezone-shifted
 * JavaScript Date representation.
 */
export function parseBirthDate(value: unknown, today = getUtcToday()): string | null {
	if (typeof value !== "string") return null;
	const match = ISO_DATE_PATTERN.exec(value);
	if (!match) return null;

	const year = Number(match[1]);
	const month = Number(match[2]);
	const day = Number(match[3]);
	if (year < 1900 || month < 1 || month > 12 || day < 1) return null;

	const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
	if (day > daysInMonth) return null;

	if (value < MIN_BIRTH_DATE || value > today) return null;
	return value;
}

/**
 * Returns true on the date the user reaches their 18th birthday. A February
 * 29 birthday is deliberately treated as March 1 in a non-leap anniversary
 * year so verification never becomes valid early.
 */
export function isAtLeast18(birthDate: string, today: string): boolean {
	const match = ISO_DATE_PATTERN.exec(birthDate);
	if (!match) return false;

	const birthYear = Number(match[1]);
	const birthMonth = Number(match[2]);
	const birthDay = Number(match[3]);
	const anniversaryYear = birthYear + 18;
	const anniversaryMonth = birthMonth === 2 && birthDay === 29 && !isLeapYear(anniversaryYear) ? 3 : birthMonth;
	const anniversaryDay = birthMonth === 2 && birthDay === 29 && !isLeapYear(anniversaryYear) ? 1 : birthDay;
	const anniversary = `${anniversaryYear.toString().padStart(4, "0")}-${anniversaryMonth
		.toString()
		.padStart(2, "0")}-${anniversaryDay.toString().padStart(2, "0")}`;
	return today >= anniversary;
}
