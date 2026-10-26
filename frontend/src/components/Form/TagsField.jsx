import { Field, useFormikContext } from "formik";
import { useState } from "react";
import CreatableSelect from "react-select/creatable";
import { intl, T } from "src/locale";
import { selectClassNames } from "src/modules/Select";

export function TagsField({ name = "npmplusTags", id = "npmplusTags", labelId, placeholderId, suggestions = [] }) {
	const { setFieldValue } = useFormikContext();
	const [inputValue, setInputValue] = useState("");

	const handleChange = (v) => {
		const tags = [...new Set((v ?? []).map((i) => i.value.trim()).filter(Boolean))].slice(0, 20);
		void setFieldValue(name, tags);
	};

	const addTags = (current, raw) => {
		const added = raw
			.split(",")
			.map((t) => t.trim())
			.filter((t) => t.length > 0 && t.length <= 64);
		void setFieldValue(name, [...new Set([...(current ?? []), ...added])].slice(0, 20));
	};

	return (
		<Field name={name}>
			{({ field }) => (
				<div className="mb-3">
					<label className="form-label" htmlFor={id}>
						<T id={labelId} />
					</label>
					<CreatableSelect
						unstyled
						classNames={selectClassNames}
						name={field.name}
						id={id}
						isMulti
						isClearable={false}
						closeMenuOnSelect={true}
						inputValue={inputValue}
						onInputChange={(v, meta) => {
							if (meta.action !== "input-change") {
								if (meta.action !== "input-blur" && meta.action !== "menu-close") setInputValue("");
								return;
							}
							// a comma finishes the current tag
							if (v.includes(",")) {
								addTags(field.value, v);
								setInputValue("");
								return;
							}
							setInputValue(v);
						}}
						options={suggestions.map((t) => ({ label: t, value: t }))}
						isValidNewOption={(input) => {
							const v = input.trim();
							return v.length > 0 && v.length <= 64 && !v.includes(",") && !field.value?.includes(v);
						}}
						formatCreateLabel={(input) => input}
						noOptionsMessage={() => null}
						placeholder={intl.formatMessage({ id: placeholderId })}
						onBlur={() => {
							// don't lose a tag that was typed but not confirmed
							if (inputValue.trim()) addTags(field.value, inputValue);
							setInputValue("");
						}}
						onChange={handleChange}
						value={(field.value ?? []).map((t) => ({ label: t, value: t }))}
					/>
				</div>
			)}
		</Field>
	);
}
