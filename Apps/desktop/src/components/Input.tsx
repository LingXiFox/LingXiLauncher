import type { InputHTMLAttributes, ReactNode, TextareaHTMLAttributes } from "react";
import { useId } from "react";
import { Icon, type IconName } from "./Icons";

interface FieldProps {
  id: string;
  label?: string;
  hint?: string;
  error?: string;
  children: ReactNode;
  className?: string;
}

export function Field({ id, label, hint, error, children, className }: FieldProps) {
  return (
    <div className={["field", className ?? ""].filter(Boolean).join(" ")}>
      {label ? (
        <label className="field__label" htmlFor={id}>
          {label}
        </label>
      ) : null}
      {children}
      {error ? (
        <p className="field__message field__message--error" role="alert">
          {error}
        </p>
      ) : hint ? (
        <p className="field__message">{hint}</p>
      ) : null}
    </div>
  );
}

interface TextInputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "size"> {
  label?: string;
  hint?: string;
  error?: string;
  leadingIcon?: IconName;
  fieldClassName?: string;
}

export function TextInput({
  label,
  hint,
  error,
  leadingIcon,
  id,
  className,
  fieldClassName,
  ...rest
}: TextInputProps) {
  const generated = useId();
  const inputId = id ?? generated;
  return (
    <Field id={inputId} label={label} hint={hint} error={error} className={fieldClassName}>
      <div className={["input-shell", leadingIcon ? "has-icon" : "", error ? "has-error" : ""].filter(Boolean).join(" ")}>
        {leadingIcon ? <Icon name={leadingIcon} size={15} className="input-shell__icon" /> : null}
        <input id={inputId} className={["input", className ?? ""].filter(Boolean).join(" ")} aria-invalid={!!error} {...rest} />
      </div>
    </Field>
  );
}

interface SearchInputProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  label: string;
  className?: string;
  onClear?: () => void;
}

export function SearchInput({ value, onChange, placeholder = "搜索", label, className, onClear }: SearchInputProps) {
  return (
    <div className={["search-input", className ?? ""].filter(Boolean).join(" ")}>
      <Icon name="search" size={15} className="search-input__icon" />
      <input
        className="search-input__field"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        aria-label={label}
        type="search"
        spellCheck={false}
      />
      {value ? (
        <button
          type="button"
          className="search-input__clear"
          aria-label="清空搜索"
          onClick={() => {
            onChange("");
            onClear?.();
          }}
        >
          <Icon name="close" size={12} />
        </button>
      ) : null}
    </div>
  );
}

interface TextAreaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  label?: string;
  hint?: string;
  error?: string;
}

export function TextArea({ label, hint, error, id, className, ...rest }: TextAreaProps) {
  const generated = useId();
  const areaId = id ?? generated;
  return (
    <Field id={areaId} label={label} hint={hint} error={error}>
      <textarea
        id={areaId}
        className={["textarea", className ?? ""].filter(Boolean).join(" ")}
        aria-invalid={!!error}
        {...rest}
      />
    </Field>
  );
}

interface SwitchProps {
  checked: boolean;
  onChange: (checked: boolean) => void;
  label: string;
  description?: string;
  disabled?: boolean;
}

export function Switch({ checked, onChange, label, description, disabled }: SwitchProps) {
  return (
    <label className={["switch-row", disabled ? "is-disabled" : ""].filter(Boolean).join(" ")}>
      <span className="switch-row__text">
        <span className="switch-row__label">{label}</span>
        {description ? <span className="switch-row__description">{description}</span> : null}
      </span>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        className={["switch", checked ? "is-on" : ""].filter(Boolean).join(" ")}
        onClick={() => onChange(!checked)}
        disabled={disabled}
      >
        <span className="switch__thumb" />
      </button>
    </label>
  );
}
