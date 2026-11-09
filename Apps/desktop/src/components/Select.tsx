import { useId } from "react";
import { Icon } from "./Icons";
import { Field } from "./Input";

export interface SelectOption {
  value: string;
  label: string;
  disabled?: boolean;
}

interface SelectProps {
  value: string;
  onChange: (value: string) => void;
  options: SelectOption[];
  label?: string;
  hint?: string;
  error?: string;
  id?: string;
  className?: string;
  disabled?: boolean;
  ariaLabel?: string;
}

export function Select({
  value,
  onChange,
  options,
  label,
  hint,
  error,
  id,
  className,
  disabled,
  ariaLabel,
}: SelectProps) {
  const generated = useId();
  const selectId = id ?? generated;
  return (
    <Field id={selectId} label={label} hint={hint} error={error} className={className}>
      <div className={["select-shell", disabled ? "is-disabled" : ""].filter(Boolean).join(" ")}>
        <select
          id={selectId}
          className="select"
          value={value}
          onChange={(event) => onChange(event.target.value)}
          disabled={disabled}
          aria-label={ariaLabel ?? label}
        >
          {options.map((option) => (
            <option key={option.value} value={option.value} disabled={option.disabled}>
              {option.label}
            </option>
          ))}
        </select>
        <Icon name="chevronDown" size={14} className="select-shell__icon" />
      </div>
    </Field>
  );
}
